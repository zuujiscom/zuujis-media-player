// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import AppKit
import Combine

/// Plays audio files — FLAC, ALAC, WAV, AIFF, MP3, AAC — through the same EQ
/// the system-wide route uses.
///
/// This is a second, fully separate audio path. It owns its own
/// `AVAudioEngine` and never touches the Core Audio process tap or the
/// aggregate device in `AudioEngine`: that tap excludes this process on
/// purpose, so the player's output reaches the speakers directly and the
/// player has to apply the EQ itself. The graph is
///
///     AVAudioPlayerNode → AVAudioUnitEQ → mainMixer → default output
///
/// `AudioEngine` stays the source of truth for the bands, bypass and master
/// gain; this class only mirrors them onto its own `AVAudioUnitEQ`.
///
/// Files are decoded natively by `AVAudioFile` at their own sample rate and
/// bit depth (float32 inside the graph, which holds any 24-bit sample exactly).
/// Nothing here resamples: the output mixer converts to the device's rate, so
/// this is lossless *decoding* but not yet bit-perfect *output*.
@MainActor
final class PlayerEngine: ObservableObject {

    enum State { case stopped, playing, paused }

    struct TrackInfo {
        var url: URL
        var title: String
        var artist: String?
        var album: String?
        var artwork: NSImage?
        var codec: String
        var sampleRate: Double
        var bitDepth: Int?
        var channels: Int
        var isLossless: Bool
        var duration: Double

        /// "FLAC · 96 kHz · 24-bit · Stereo"
        var formatSummary: String {
            var parts = [codec, String(format: "%g kHz", sampleRate / 1000)]
            if let bitDepth { parts.append("\(bitDepth)-bit") }
            switch channels {
            case 1: parts.append("Mono")
            case 2: parts.append("Stereo")
            default: parts.append("\(channels) ch")
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Published state

    @Published private(set) var state: State = .stopped
    @Published private(set) var track: TrackInfo?
    @Published private(set) var errorMessage: String?

    /// Player volume, 0…1, ahead of the EQ's master gain. Persists.
    @Published var volume: Float {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        }
    }
    private static let volumeKey = "playerVolume"

    // MARK: - Audio graph

    // Replaced whenever the graph is rebuilt: like the system route, a fresh
    // engine is more reliable than reusing one after its configuration changed.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var eqNode = AVAudioUnitEQ(numberOfBands: EQPreset.defaultBands.count)
    private var file: AVAudioFile?

    /// Mirrors the bands, bypass and master gain from here.
    private weak var equalizer: AudioEngine?
    private var cancellables = Set<AnyCancellable>()
    private var configObserver: NSObjectProtocol?

    /// Bumped by every schedule, stop and rebuild. A scheduled segment's
    /// completion handler also fires when the node is stopped for a seek, so a
    /// handler only counts if it still belongs to the current session —
    /// otherwise every seek would look like "the track ended".
    private var session = 0

    /// Frame where the current schedule began, and the frame a pause stopped at.
    private var startFrame: AVAudioFramePosition = 0
    private var pausedFrame: AVAudioFramePosition = 0

    // MARK: - Metering

    private let analyzer = SpectrumAnalyzer()
    private let latest = LatestFrame()

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.volumeKey) as? Float
        _volume = Published(initialValue: min(1, max(0, stored ?? 1)))
    }

    /// Connects the player to the EQ it shares with the system route. Called
    /// once at launch; safe to call again.
    func attach(to equalizer: AudioEngine) {
        guard self.equalizer == nil else { return }
        self.equalizer = equalizer

        // `@Published` fires before the value is stored, so hop a run-loop turn
        // and read the settled values.
        Publishers.Merge3(
            equalizer.$bands.map { _ in () },
            equalizer.$isBypassed.map { _ in () },
            equalizer.$masterGain.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.applyEQ() }
        }
        .store(in: &cancellables)

        // While a file is playing, the visualizer reads the player's own
        // samples: the system tap can't see this process's output.
        equalizer.externalVisualizerFrame = { [weak self] in
            guard let self, self.state == .playing else { return nil }
            return self.latest.read()
        }
    }

    // MARK: - Transport

    func open(_ url: URL) {
        do {
            let opened = try AVAudioFile(forReading: url)
            tearDownGraph()
            file = opened
            let info = Self.makeInfo(for: opened, url: url)
            track = info
            errorMessage = nil
            try buildGraph(format: opened.processingFormat)
            try startPlayback(from: 0, playing: true)
            loadMetadata(for: url)
        } catch {
            tearDownGraph()
            file = nil
            track = nil
            state = .stopped
            errorMessage = "Couldn't play \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .stopped:
            guard file != nil else { return }
            fail { try startPlayback(from: 0, playing: true) }
        }
    }

    func pause() {
        guard state == .playing else { return }
        pausedFrame = currentFrame()
        player.pause()
        state = .paused
        clearMeters()
    }

    func resume() {
        guard state == .paused else { return }
        player.play()
        state = .playing
    }

    func stop() {
        guard file != nil else { return }
        session += 1
        player.stop()
        engine.stop()
        startFrame = 0
        pausedFrame = 0
        state = .stopped
        clearMeters()
    }

    func seek(to seconds: Double) {
        guard let file, state != .stopped else { return }
        let rate = file.processingFormat.sampleRate
        let frame = AVAudioFramePosition(max(0, min(seconds, track?.duration ?? seconds)) * rate)
        fail { try startPlayback(from: frame, playing: state == .playing) }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime() + seconds)
    }

    /// Seconds into the track. Polled by the UI rather than published: a
    /// published position would redraw every view that observes the player on
    /// each tick.
    func currentTime() -> Double {
        guard let file else { return 0 }
        return Double(currentFrame()) / file.processingFormat.sampleRate
    }

    private func currentFrame() -> AVAudioFramePosition {
        guard let file else { return 0 }
        switch state {
        case .stopped:
            return 0
        case .paused:
            return pausedFrame
        case .playing:
            guard let nodeTime = player.lastRenderTime,
                  let playerTime = player.playerTime(forNodeTime: nodeTime) else { return startFrame }
            return min(file.length, startFrame + max(0, playerTime.sampleTime))
        }
    }

    // MARK: - Scheduling

    /// (Re)schedules the file from `frame` and, when `playing`, starts it.
    private func startPlayback(from frame: AVAudioFramePosition, playing: Bool) throws {
        guard let file else { return }

        // Invalidate first: stopping the node fires the old segment's handler.
        session += 1
        let token = session
        player.stop()

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        let remaining = file.length - frame
        guard remaining > 0 else {
            finish()
            return
        }

        player.scheduleSegment(
            file,
            startingFrame: frame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in self?.segmentFinished(token) }
        }

        startFrame = frame
        pausedFrame = frame
        if playing {
            player.play()
            state = .playing
        } else {
            state = .paused
        }
    }

    private func segmentFinished(_ token: Int) {
        guard token == session else { return }
        finish()
    }

    private func finish() {
        session += 1
        player.stop()
        engine.stop()
        startFrame = 0
        pausedFrame = 0
        state = .stopped
        clearMeters()
    }

    private func fail(_ body: () throws -> Void) {
        do {
            try body()
            errorMessage = nil
        } catch {
            errorMessage = "Playback failed: \(error.localizedDescription)"
            session += 1
            player.stop()
            engine.stop()
            state = .stopped
            clearMeters()
        }
    }

    // MARK: - Graph

    private func buildGraph(format: AVAudioFormat) throws {
        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        let bandCount = equalizer?.bands.count ?? EQPreset.defaultBands.count
        let newEQ = AVAudioUnitEQ(numberOfBands: bandCount)

        newEngine.attach(newPlayer)
        newEngine.attach(newEQ)
        newEngine.connect(newPlayer, to: newEQ, format: format)
        newEngine.connect(newEQ, to: newEngine.mainMixerNode, format: format)
        newPlayer.volume = volume

        engine = newEngine
        player = newPlayer
        eqNode = newEQ
        applyEQ()
        installMeterTap()

        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        // The output device changed or the hardware reconfigured: the engine
        // has stopped itself, and the player node has lost its schedule.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: newEngine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildGraph() }
        }
    }

    private func tearDownGraph() {
        session += 1
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        removeMeterTap()
        player.stop()
        engine.stop()
        state = .stopped
        clearMeters()
    }

    /// Rebuilds on a fresh engine and resumes where it was. Used when the
    /// output device changes and when the band count does.
    private func rebuildGraph() {
        guard let file else { return }
        let wasState = state
        let frame = wasState == .stopped ? 0 : currentFrame()

        session += 1
        removeMeterTap()
        player.stop()
        engine.stop()

        do {
            try buildGraph(format: file.processingFormat)
            if wasState != .stopped {
                try startPlayback(from: frame, playing: wasState == .playing)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Playback failed: \(error.localizedDescription)"
            state = .stopped
            clearMeters()
        }
    }

    // MARK: - EQ

    /// Same mapping as `AudioEngine.syncEQNode`: `bands` is what the user wants
    /// to hear, and the node is given the overlap-compensated gains that
    /// deliver it. Never write `bands[i].gain` straight to the node.
    private func applyEQ() {
        guard let equalizer else { return }
        let effective = EQResponse.compensated(equalizer.bands)

        // `AVAudioUnitEQ` has a fixed band count.
        if effective.count != eqNode.bands.count {
            rebuildGraph()
            return
        }

        for (i, band) in effective.enumerated() {
            let f = eqNode.bands[i]
            f.filterType = band.filterType.avType
            f.frequency = Float(band.frequency)
            f.gain = Float(band.gain)
            f.bandwidth = Float(band.bandwidth)
            f.bypass = !band.isEnabled || equalizer.isBypassed
        }
        eqNode.globalGain = Float(min(24, max(-96, equalizer.amplificationDB)))
    }

    // MARK: - Metering

    /// Taps the EQ's output — what the listener hears — and turns it into the
    /// same spectrum, level and waveform the system route produces, so the
    /// response graph and the visualizer work for files too.
    private func installMeterTap() {
        let analyzer = analyzer
        let latest = latest
        let meters = equalizer?.meters
        eqNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let total = Int(buffer.frameLength)
            guard total > 0 else { return }

            let waveformCount = 256
            var waveform = [Float](repeating: 0, count: waveformCount)
            for i in 0..<waveformCount {
                waveform[i] = channel[total > waveformCount ? i * total / waveformCount : min(i, total - 1)]
            }

            // Short tail for transients, and a one-pole low pass near 150 Hz for
            // the bass term — as in `AudioEngine.visualizerFrame`.
            let tail = min(total, 512)
            let sampleRate = Float(buffer.format.sampleRate > 0 ? buffer.format.sampleRate : 48000)
            let alpha = min(1, 2 * Float.pi * 150 / sampleRate)
            var sum: Float = 0, bassSum: Float = 0, lp: Float = 0
            for i in (total - tail)..<total {
                let x = channel[i]
                sum += x * x
                lp += alpha * (x - lp)
                bassSum += lp * lp
            }

            let spectrum = analyzer.analyze(buffer: buffer)
            let frame = VisualizerFrame(
                waveform: waveform,
                spectrum: spectrum,
                bass: min(1, sqrtf(bassSum / Float(tail)) * 6),
                level: min(1, sqrtf(sum / Float(tail)) * 3)
            )
            latest.write(frame)

            let snapshot = MeterSnapshot(
                spectrum: spectrum,
                level: min(1, analyzer.rms(buffer: buffer) * 3),
                latencyMs: 0
            )
            DispatchQueue.main.async { meters?.snapshot = snapshot }
        }
    }

    /// `removeTap` throws an Objective-C exception on a node that is not
    /// attached to an engine, which is the case before the first graph exists.
    private func removeMeterTap() {
        guard eqNode.engine != nil else { return }
        eqNode.removeTap(onBus: 0)
    }

    /// Silence must read as silence: with the tap stopped, the last frame would
    /// otherwise keep the graph and the visualizer animating.
    private func clearMeters() {
        latest.clear()
        if equalizer?.isRunning != true {
            equalizer?.meters.snapshot = MeterSnapshot()
        }
    }

    // MARK: - Track info

    private static func makeInfo(for file: AVAudioFile, url: URL) -> TrackInfo {
        let format = file.fileFormat
        let asbd = format.streamDescription.pointee
        let rate = file.processingFormat.sampleRate

        var depth = Int(asbd.mBitsPerChannel)
        if let d = format.settings[AVLinearPCMBitDepthKey] as? Int, d > 0 { depth = d }
        if asbd.mFormatID == kAudioFormatAppleLossless || asbd.mFormatID == kAudioFormatFLAC {
            // Both record their source depth in the format flags (1 = 16-bit,
            // 2 = 20, 3 = 24, 4 = 32); `mBitsPerChannel` is 0 for them.
            switch asbd.mFormatFlags {
            case 1: depth = 16
            case 2: depth = 20
            case 3: depth = 24
            case 4: depth = 32
            default: break
            }
        }

        let codec: String
        let lossless: Bool
        switch asbd.mFormatID {
        case kAudioFormatFLAC: codec = "FLAC"; lossless = true
        case kAudioFormatAppleLossless: codec = "ALAC"; lossless = true
        case kAudioFormatLinearPCM:
            codec = url.pathExtension.lowercased().hasPrefix("aif") ? "AIFF"
                : url.pathExtension.lowercased() == "caf" ? "CAF" : "WAV"
            lossless = true
        case kAudioFormatMPEGLayer3: codec = "MP3"; lossless = false
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_LD: codec = "AAC"; lossless = false
        default: codec = url.pathExtension.uppercased(); lossless = false
        }

        return TrackInfo(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            artist: nil,
            album: nil,
            artwork: nil,
            codec: codec,
            sampleRate: rate,
            bitDepth: depth > 0 && lossless ? depth : nil,
            channels: Int(file.processingFormat.channelCount),
            isLossless: lossless,
            duration: rate > 0 ? Double(file.length) / rate : 0
        )
    }

    /// Title, artist, album and cover art from the file's tags, filled in once
    /// they load. The file name stands in until then.
    private func loadMetadata(for url: URL) {
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let items = try? await asset.load(.commonMetadata) else { return }

            func value(_ id: AVMetadataIdentifier) -> AVMetadataItem? {
                AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first
            }
            let title = try? await value(.commonIdentifierTitle)?.load(.stringValue)
            let artist = try? await value(.commonIdentifierArtist)?.load(.stringValue)
            let album = try? await value(.commonIdentifierAlbumName)?.load(.stringValue)
            let artData = try? await value(.commonIdentifierArtwork)?.load(.dataValue)

            guard let self, self.track?.url == url else { return }
            if let title, !title.isEmpty { self.track?.title = title }
            self.track?.artist = artist
            self.track?.album = album
            if let artData { self.track?.artwork = NSImage(data: artData) }
        }
    }
}

/// The newest analysis frame, handed from the tap's thread to the main actor.
private final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: VisualizerFrame?

    func write(_ new: VisualizerFrame) {
        lock.lock(); frame = new; lock.unlock()
    }

    func read() -> VisualizerFrame? {
        lock.lock(); defer { lock.unlock() }
        return frame
    }

    func clear() {
        lock.lock(); frame = nil; lock.unlock()
    }
}
