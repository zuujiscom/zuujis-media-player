// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import Foundation
import WidgetKit

/// Keeps the desktop widgets (`ZuujisWidgets`) in step with the app, and
/// carries out the buttons on them. See `WidgetState` for the file exchange.
///
/// The app writes only when something a widget shows changes, after a short
/// pause so a slider drag is one write, then asks WidgetKit to reload. Between
/// writes the widgets run themselves: the progress bar counts with a timer view
/// and the lyric line changes through pre-scheduled timeline entries, so
/// nothing here ticks.
@MainActor
final class WidgetBridge {
    private let player: PlayerEngine
    private let engine: AudioEngine
    private let presets: PresetManager
    private let lyrics: LyricsStore
    private var cancellables = Set<AnyCancellable>()
    private var watcher: DispatchSourceFileSystemObject?
    private var artworkFor: URL?

    init(player: PlayerEngine, engine: AudioEngine, presets: PresetManager, lyrics: LyricsStore) {
        self.player = player
        self.engine = engine
        self.presets = presets
        self.lyrics = lyrics
    }

    func start() {
        guard cancellables.isEmpty else { return }
        WidgetFiles.folderOverride = AppPaths.support

        Publishers.MergeMany([
            player.$state.map { _ in () }.eraseToAnyPublisher(),
            player.$track.map { _ in () }.eraseToAnyPublisher(),
            player.$speed.map { _ in () }.eraseToAnyPublisher(),
            player.timelineChanged.eraseToAnyPublisher(),
            lyrics.$lyrics.map { _ in () }.eraseToAnyPublisher(),
            engine.$isRunning.map { _ in () }.eraseToAnyPublisher(),
            engine.$isBypassed.map { _ in () }.eraseToAnyPublisher(),
            engine.$masterGain.map { _ in () }.eraseToAnyPublisher(),
            engine.$bands.map { _ in () }.eraseToAnyPublisher(),
            presets.$selectedPresetID.map { _ in () }.eraseToAnyPublisher(),
        ])
        .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
        .sink { [weak self] in MainActor.assumeIsolated { self?.publish() } }
        .store(in: &cancellables)

        watchCommands()
        publish()
    }

    // MARK: App → widgets

    private func publish() {
        var state = WidgetState()
        if let track = player.track {
            state.hasTrack = true
            state.title = track.title
            state.artist = track.artist ?? ""
            state.album = track.album ?? ""
            state.format = track.formatSummary
            state.duration = track.duration
            writeArtwork(for: track)
        } else {
            artworkFor = nil
            try? FileManager.default.removeItem(at: WidgetFiles.art)
        }
        state.isPlaying = player.state == .playing
        state.position = player.currentTime()
        state.anchor = Date()
        state.speed = player.speed
        if let lines = lyrics.lyrics, lines.isSynced, lyrics.url == player.track?.url {
            state.lyrics = lines.lines.compactMap { line in line.time.map { .init(t: $0, s: line.text) } }
        }
        state.eqOn = engine.isRunning
        state.bypassed = engine.isBypassed
        state.preset = presets.selectedPreset?.name ?? ""
        state.preampDB = engine.amplificationDB
        state.bands = engine.bands.map { .init(f: $0.frequency, g: $0.gain) }
        state.bass = average(of: engine.bands.filter { $0.frequency < 250 })
        state.mid = average(of: engine.bands.filter { $0.frequency >= 250 && $0.frequency <= 4000 })
        state.treble = average(of: engine.bands.filter { $0.frequency > 4000 })
        state.presets = (EQPreset.allBuiltin + presets.customPresets).map(\.name)

        WidgetFiles.write(state)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func average(of bands: [EQBand]) -> Double {
        bands.isEmpty ? 0 : bands.map(\.gain).reduce(0, +) / Double(bands.count)
    }

    /// A small JPEG of the cover, once per song.
    private func writeArtwork(for track: PlayerEngine.TrackInfo) {
        guard artworkFor != track.url, let image = track.artwork else { return }
        let side: CGFloat = 320
        let scaled = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Fill the square, centred.
            let source = image.size
            let scale = max(side / source.width, side / source.height)
            let size = NSSize(width: source.width * scale, height: source.height * scale)
            image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                  width: size.width, height: size.height))
            return true
        }
        guard let tiff = scaled.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try? jpeg.write(to: WidgetFiles.art, options: .atomic)
        artworkFor = track.url
    }

    // MARK: Widgets → app

    private func watchCommands() {
        let folder = WidgetFiles.commands
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.runCommands() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        runCommands()
    }

    private func runCommands() {
        let folder = WidgetFiles.commands
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let command = try? JSONDecoder().decode(WidgetCommand.self, from: data) else { continue }
            run(command)
        }
    }

    /// The preamp in dB steps, within the slider's own range.
    private func stepPreamp(by db: Double) {
        let target = engine.amplificationDB + db
        engine.masterGain = min(AudioEngine.maxGain, max(0.25, pow(10, target / 20)))
    }

    /// Moves every band in a region by `db`: bass is under 250 Hz, treble
    /// over 4 kHz, mid between.
    private func nudgeTone(_ region: String, by db: Double) {
        for (index, band) in engine.bands.enumerated() {
            let f = band.frequency
            let inRegion = region == "bass" ? f < 250 : (region == "treble" ? f > 4000 : (f >= 250 && f <= 4000))
            if inRegion {
                engine.setGain(min(AudioEngine.maxBandGain, max(AudioEngine.minBandGain, band.gain + db)), forBand: index)
            }
        }
    }

    private func run(_ command: WidgetCommand) {
        switch command.name {
        case "playPause": player.togglePlayPause()
        case "next": player.next()
        case "previous": player.previous()
        case "eqPower": engine.isRunning ? engine.stop() : engine.start()
        case "eqBypass": engine.toggleBypass()
        case "preamp":
            if let step = command.amount, step != 0 { stepPreamp(by: step) } else { engine.masterGain = 1 }
        case "tone":
            if let region = command.arg, let step = command.amount { nudgeTone(region, by: step) }
        case "flat": engine.resetToFlat()
        case "preset":
            if let name = command.arg, let found = (EQPreset.allBuiltin + presets.customPresets).first(where: { $0.name == name }) {
                presets.selectedPresetID = found.id
                engine.applyPreset(found)
            }
        case "nextPreset":
            let all = EQPreset.allBuiltin + presets.customPresets
            guard !all.isEmpty else { return }
            let index = all.firstIndex { $0.id == presets.selectedPresetID } ?? -1
            let next = all[(index + 1) % all.count]
            presets.selectedPresetID = next.id
            engine.applyPreset(next)
        default: break
        }
    }
}
