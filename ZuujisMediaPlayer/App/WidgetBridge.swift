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
    private let playlists: PlaylistStore
    private let settings: WidgetSettingsStore
    /// What the widgets were last told, so nothing is written or reloaded
    /// when a change did not reach anything they show.
    private var published: WidgetState?
    private var cancellables = Set<AnyCancellable>()
    private var watcher: DispatchSourceFileSystemObject?
    private var artworkFor: URL?

    init(player: PlayerEngine, engine: AudioEngine, presets: PresetManager, lyrics: LyricsStore,
         playlists: PlaylistStore, settings: WidgetSettingsStore) {
        self.player = player
        self.engine = engine
        self.presets = presets
        self.lyrics = lyrics
        self.playlists = playlists
        self.settings = settings
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
            lyrics.$offset.map { _ in () }.eraseToAnyPublisher(),
            engine.$isRunning.map { _ in () }.eraseToAnyPublisher(),
            engine.$isBypassed.map { _ in () }.eraseToAnyPublisher(),
            engine.$masterGain.map { _ in () }.eraseToAnyPublisher(),
            engine.$bands.map { _ in () }.eraseToAnyPublisher(),
            presets.$selectedPresetID.map { _ in () }.eraseToAnyPublisher(),
            // A saved, renamed or deleted preset changes the widget's buttons.
            presets.$customPresets.map { _ in () }.eraseToAnyPublisher(),
            playlists.$favoritePaths.map { _ in () }.eraseToAnyPublisher(),
            settings.$settings.map { _ in () }.eraseToAnyPublisher(),
        ])
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
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
            state.favorite = playlists.isFavorite(track.url.path)
        }
        let artChanged = writeArtwork(for: player.track)
        state.isPlaying = player.state == .playing
        state.position = player.currentTime()
        state.anchor = Date()
        state.speed = player.speed
        if let lines = lyrics.lyrics, lines.isSynced, lyrics.url == player.track?.url {
            // Line times in the widget's own clock: later by what the output
            // adds, earlier by the song's adjustment.
            let shift = player.outputLatency - lyrics.offset
            state.lyrics = lines.lines.compactMap { line in line.time.map { .init(t: $0 + shift, s: line.text) } }
        }
        state.eqOn = engine.isRunning
        state.bypassed = engine.isBypassed
        state.preset = presets.selectedPreset?.name ?? ""
        state.preampDB = engine.amplificationDB
        state.bands = engine.bands.map { .init(f: $0.frequency, g: $0.gain) }
        state.bass = average(of: engine.bands.filter { $0.frequency < 250 })
        state.mid = average(of: engine.bands.filter { $0.frequency >= 250 && $0.frequency <= 4000 })
        state.treble = average(of: engine.bands.filter { $0.frequency > 4000 })
        state.presets = settings.settings.offeredPresets(from: presets.allPresets.map(\.name))
        state.settings = settings.settings

        // Most events (a tag filling in, a meter-driven republish) change
        // nothing a widget shows. The position counts as unchanged while it
        // is where the widgets already expect it to be.
        if let old = published, !artChanged {
            var same = old
            same.anchor = state.anchor
            same.position = state.position
            if same == state, abs(state.position - old.position(at: state.anchor)) < 0.35 { return }
        }
        published = state
        WidgetFiles.write(state)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func average(of bands: [EQBand]) -> Double {
        bands.isEmpty ? 0 : bands.map(\.gain).reduce(0, +) / Double(bands.count)
    }

    /// A small JPEG of the cover, once per song; removed when the song has
    /// none, so the widgets never keep the previous song's cover. Returns
    /// whether the file changed.
    private func writeArtwork(for track: PlayerEngine.TrackInfo?) -> Bool {
        guard let track, let image = track.artwork, image.size.width > 0, image.size.height > 0 else {
            guard artworkFor != nil || FileManager.default.fileExists(atPath: WidgetFiles.art.path) else { return false }
            artworkFor = nil
            try? FileManager.default.removeItem(at: WidgetFiles.art)
            return true
        }
        guard artworkFor != track.url else { return false }
        let side: CGFloat = 320
        let scaled = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // Fill the square, centred.
            let source = image.size
            let scale = max(side / source.width, side / source.height)
            let size = NSSize(width: source.width * scale, height: source.height * scale)
            image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                  width: size.width, height: size.height))
            return true
        }
        guard let tiff = scaled.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
              (try? jpeg.write(to: WidgetFiles.art, options: .atomic)) != nil else { return false }
        artworkFor = track.url
        return true
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
        // Buttons pressed while the app was not running are thrown away:
        // carrying them out now would toggle things the user gave up on.
        runCommands(discard: true)
    }

    private func runCommands(discard: Bool = false) {
        let folder = WidgetFiles.commands
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        // In the order they were pressed: two quick taps of + are two steps.
        let ordered = files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        var ran = false
        for file in ordered {
            defer { try? FileManager.default.removeItem(at: file) }
            guard !discard, let data = try? Data(contentsOf: file),
                  let command = try? JSONDecoder().decode(WidgetCommand.self, from: data) else { continue }
            if let sent = command.sent, Date().timeIntervalSince(sent) > 20 { continue }
            run(command)
            ran = true
        }
        // Answer a tap at once instead of waiting out the debounce.
        if ran { publish() }
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
        case "favorite":
            if let track = player.track { _ = playlists.toggleFavorite(track.url.path) }
        // Choosing a preset only selects it; the app applies whatever is
        // selected (see `bootstrap`), the same as its own menus.
        case "preset":
            if let name = command.arg, let found = presets.allPresets.first(where: { $0.name == name }) {
                presets.selectedPresetID = found.id
            }
        case "nextPreset":
            // Steps through the presets the widget offers, not all of them.
            let names = settings.settings.offeredPresets(from: presets.allPresets.map(\.name))
            guard !names.isEmpty else { return }
            let index = names.firstIndex(of: presets.selectedPreset?.name ?? "") ?? -1
            let next = names[(index + 1) % names.count]
            if let found = presets.allPresets.first(where: { $0.name == next }) { presets.selectedPresetID = found.id }
        default: break
        }
    }
}
