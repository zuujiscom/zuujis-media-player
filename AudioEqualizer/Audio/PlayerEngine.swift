// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import AppKit
import Combine

/// Plays a queue of audio files — FLAC, ALAC, WAV, AIFF, MP3, AAC — through the
/// same EQ the system-wide route uses.
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
/// **Gapless playback.** While a track plays, the next one is already scheduled
/// on the same player node, so the node never runs dry and the join is
/// sample-exact. That only works when the next file has the graph's sample rate
/// and channel count; otherwise the graph is rebuilt at the end of the track,
/// which costs a short gap. See `scheduleNext`.
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

    let queue: PlaybackQueue

    /// Fires when the timeline jumps — a seek, a new track, play or pause — so
    /// Now Playing can resync its elapsed time.
    let timelineChanged = PassthroughSubject<Void, Never>()

    // MARK: - Audio graph

    // Replaced whenever the graph is rebuilt: like the system route, a fresh
    // engine is more reliable than reusing one after its configuration changed.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var eqNode = AVAudioUnitEQ(numberOfBands: EQPreset.defaultBands.count)

    /// What the graph was built for. A track with a different sample rate or
    /// channel count needs a rebuild; one with the same plays gaplessly.
    private var graphFormat: AVAudioFormat?

    /// Mirrors the bands, bypass and master gain from here.
    private weak var equalizer: AudioEngine?
    private var cancellables = Set<AnyCancellable>()
    private var configObserver: NSObjectProtocol?

    // MARK: - Scheduling

    /// One scheduled stretch of one file. `startSample` is where it begins on
    /// the player node's own timeline, which keeps counting across segments —
    /// that is how a position is found without trusting callback timing.
    private struct Segment {
        var id: Int
        var itemID: QueueItem.ID
        var file: AVAudioFile
        var info: TrackInfo
        var fileStart: AVAudioFramePosition
        var startSample: AVAudioFramePosition
        var frames: AVAudioFramePosition
    }

    /// The playing segment first, then at most one scheduled after it.
    private var segments: [Segment] = []
    private var nextSegmentID = 0

    /// Bumped by every session start, stop and rebuild. A scheduled segment's
    /// completion handler also fires when the node is stopped for a seek, so a
    /// handler only counts if it still belongs to the current session —
    /// otherwise every seek would look like "the track ended".
    private var session = 0

    /// The track that could not be pre-scheduled (a different format, or
    /// unreadable), so reconciling the queue does not keep retrying it.
    private var unschedulableNext: QueueItem.ID?

    /// The frame a pause stopped at.
    private var pausedFrame: AVAudioFramePosition = 0

    /// Tracks currently scheduled on the node: 2 means the next one is already
    /// queued behind the playing one, which is what makes a join gapless.
    var scheduledTrackCount: Int { segments.count }

    // MARK: - Metering

    private let analyzer = SpectrumAnalyzer()
    private let latest = LatestFrame()

    init(queue: PlaybackQueue? = nil) {
        self.queue = queue ?? PlaybackQueue()
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

        // Editing the queue can invalidate what is already scheduled.
        Publishers.Merge4(
            queue.$items.map { _ in () },
            queue.$currentID.map { _ in () },
            queue.$shuffle.map { _ in () },
            queue.$repeatMode.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.reconcileWithQueue() }
        }
        .store(in: &cancellables)

        // While a file is playing, the visualizer reads the player's own
        // samples: the system tap can't see this process's output.
        equalizer.externalVisualizerFrame = { [weak self] in
            guard let self, self.state == .playing else { return nil }
            return self.latest.read()
        }

        nowPlaying = NowPlayingController(player: self)
        restoreCurrentTrack()
    }

    private var nowPlaying: NowPlayingController?

    /// After a relaunch the queue remembers what was playing; show it in the
    /// bar, ready to resume, without starting any audio.
    private func restoreCurrentTrack() {
        guard track == nil, let item = queue.current,
              let file = try? AVAudioFile(forReading: item.url) else { return }
        track = Self.makeInfo(for: file, item: item)
        loadMetadata(for: item.url)
    }

    // MARK: - Transport

    /// Replaces the queue with these files (or the audio in these folders) and
    /// plays the first.
    func open(_ urls: [URL]) {
        let added = queue.add(urls: urls, replacing: true)
        guard let first = added.first else {
            errorMessage = "No playable audio files found."
            return
        }
        play(first.id)
    }

    /// Adds to the end of the queue without interrupting what is playing.
    func enqueue(_ urls: [URL]) {
        let hadCurrent = queue.currentID != nil
        let added = queue.add(urls: urls)
        if !hadCurrent, let first = added.first, state == .stopped {
            queue.setCurrent(first.id)
            restoreCurrentTrack()
        }
        // What is playing may now have a next track to pre-schedule.
        reconcileWithQueue()
    }

    func play(_ id: QueueItem.ID) {
        playItem(id, attempts: 0)
    }

    /// Unreadable files are skipped (once around the queue at most), so one bad
    /// file cannot stall an album.
    private func playItem(_ id: QueueItem.ID, attempts: Int) {
        guard let item = queue.item(withID: id) else { return }
        queue.setCurrent(id)
        do {
            let segment = try makeSegment(for: item, fileStart: 0, startSample: 0)
            try prepareGraph(for: segment.file.processingFormat)
            track = segment.info
            errorMessage = nil
            try startSession(segment, playing: true)
            loadMetadata(for: item.url)
        } catch {
            errorMessage = "Couldn't play \(item.url.lastPathComponent): \(error.localizedDescription)"
            if attempts < queue.items.count, let next = queue.itemForSkipForward(), next.id != id {
                playItem(next.id, attempts: attempts + 1)
            } else {
                finish()
            }
        }
    }

    func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .stopped:
            if let id = queue.currentID ?? queue.items.first?.id { play(id) }
        }
    }

    func pause() {
        guard state == .playing else { return }
        pausedFrame = currentFrame()
        player.pause()
        state = .paused
        clearMeters()
        timelineChanged.send()
    }

    func resume() {
        guard state == .paused else { return }
        player.play()
        state = .playing
        timelineChanged.send()
    }

    func stop() {
        guard state != .stopped else { return }
        finish()
    }

    func next() {
        if let item = queue.itemForSkipForward() {
            play(item.id)
        } else {
            finish()
        }
    }

    /// Past the first few seconds, Previous restarts the track, as on any
    /// player; near the start it goes back one.
    func previous() {
        if state != .stopped, currentTime() > 3 {
            seek(to: 0)
        } else if let item = queue.itemForSkipBack() {
            play(item.id)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        guard state != .stopped, let first = segments.first, let rate = graphFormat?.sampleRate else { return }
        let duration = Double(first.file.length) / rate
        let frame = AVAudioFramePosition(max(0, min(seconds, duration)) * rate)
        resume(segment: first, at: frame, playing: state == .playing)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime() + seconds)
    }

    /// Seconds into the current track. Polled by the UI rather than published:
    /// a published position would redraw every view that observes the player on
    /// each tick.
    func currentTime() -> Double {
        guard let rate = graphFormat?.sampleRate, rate > 0 else { return 0 }
        return Double(currentFrame()) / rate
    }

    /// The frame within the current file. While playing it is read off the
    /// player node's own clock and matched against the scheduled segments, so
    /// it is right through a gapless join even before the join's callback runs.
    private func currentFrame() -> AVAudioFramePosition {
        switch state {
        case .stopped:
            return 0
        case .paused:
            return pausedFrame
        case .playing:
            guard let first = segments.first else { return 0 }
            guard let nodeTime = player.lastRenderTime,
                  let playerTime = player.playerTime(forNodeTime: nodeTime) else { return first.fileStart }
            let t = max(0, playerTime.sampleTime)
            for segment in segments where t < segment.startSample + segment.frames {
                return segment.fileStart + (t - segment.startSample)
            }
            let last = segments[segments.count - 1]
            return last.fileStart + last.frames
        }
    }

    // MARK: - Sessions

    private func makeSegment(for item: QueueItem, fileStart: AVAudioFramePosition,
                             startSample: AVAudioFramePosition) throws -> Segment {
        let file = try AVAudioFile(forReading: item.url)
        nextSegmentID += 1
        return Segment(
            id: nextSegmentID,
            itemID: item.id,
            file: file,
            info: Self.makeInfo(for: file, item: item),
            fileStart: fileStart,
            startSample: startSample,
            frames: file.length - fileStart
        )
    }

    /// Restarts `segment`'s file from `frame` — a seek, or a re-schedule after
    /// the queue changed.
    private func resume(segment: Segment, at frame: AVAudioFramePosition, playing: Bool) {
        var restarted = segment
        nextSegmentID += 1
        restarted.id = nextSegmentID
        restarted.fileStart = frame
        restarted.startSample = 0
        restarted.frames = segment.file.length - frame
        do {
            try startSession(restarted, playing: playing)
            errorMessage = nil
        } catch {
            errorMessage = "Playback failed: \(error.localizedDescription)"
            finish()
        }
    }

    /// Starts a fresh session on `segment` and, when `playing`, plays it. The
    /// next track is scheduled behind it for gapless playback.
    private func startSession(_ segment: Segment, playing: Bool) throws {
        // Invalidate first: stopping the node fires the old segment's handler.
        session += 1
        let token = session
        player.stop()

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        segments = []
        unschedulableNext = nil
        guard segment.frames > 0 else {
            finish()
            return
        }

        var first = segment
        first.startSample = 0
        schedule(first, token: token)
        segments = [first]
        pausedFrame = first.fileStart
        scheduleNext(token: token)

        if playing {
            player.play()
            state = .playing
        } else {
            state = .paused
        }
        timelineChanged.send()
    }

    private func schedule(_ segment: Segment, token: Int) {
        let id = segment.id
        player.scheduleSegment(
            segment.file,
            startingFrame: segment.fileStart,
            frameCount: AVAudioFrameCount(segment.frames),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in self?.segmentFinished(token: token, segmentID: id) }
        }
    }

    /// Schedules the track after the current one behind it, if the queue has
    /// one and it can join without a rebuild.
    private func scheduleNext(token: Int) {
        guard segments.count == 1, let last = segments.last,
              let item = queue.itemAfterCurrent(),
              let graphFormat else { return }

        do {
            let segment = try makeSegment(
                for: item, fileStart: 0, startSample: last.startSample + last.frames
            )
            let format = segment.file.processingFormat
            guard segment.frames > 0,
                  format.sampleRate == graphFormat.sampleRate,
                  format.channelCount == graphFormat.channelCount else {
                // A different format needs a new graph; that happens when the
                // current track ends, at the cost of a short gap.
                unschedulableNext = item.id
                return
            }
            schedule(segment, token: token)
            segments.append(segment)
        } catch {
            unschedulableNext = item.id
        }
    }

    private func segmentFinished(token: Int, segmentID: Int) {
        guard token == session, let first = segments.first, first.id == segmentID else { return }
        segments.removeFirst()

        if let playing = segments.first {
            // The join already happened in the audio; catch the bookkeeping up.
            queue.setCurrent(playing.itemID)
            track = playing.info
            loadMetadata(for: playing.info.url)
            scheduleNext(token: token)
            timelineChanged.send()
        } else if let item = queue.itemAfterCurrent() {
            // Nothing was pre-scheduled: a different format, or an unreadable file.
            playItem(item.id, attempts: 0)
        } else {
            finish()
        }
    }

    /// Brings what is scheduled in line with the queue after an edit.
    private func reconcileWithQueue() {
        guard state != .stopped, let first = segments.first else { return }

        // The current item was removed from the queue.
        if queue.currentID != first.itemID {
            if let id = queue.currentID, state == .playing {
                play(id)
            } else {
                finish()
            }
            return
        }

        let wanted = queue.itemAfterCurrent()?.id
        let scheduled = segments.count > 1 ? segments[1].itemID : nil
        guard wanted != scheduled, wanted != unschedulableNext || scheduled != nil else { return }

        // Re-deal from where it is. A brief gap, only when the queue is edited.
        resume(segment: first, at: currentFrame(), playing: state == .playing)
    }

    private func finish() {
        session += 1
        player.stop()
        engine.stop()
        segments = []
        pausedFrame = 0
        state = .stopped
        clearMeters()
        timelineChanged.send()
    }

    // MARK: - Graph

    /// Builds the graph unless the existing one already fits this format.
    private func prepareGraph(for format: AVAudioFormat) throws {
        if let graphFormat, graphFormat.sampleRate == format.sampleRate,
           graphFormat.channelCount == format.channelCount, eqNode.engine != nil {
            return
        }
        session += 1
        removeMeterTap()
        player.stop()
        engine.stop()
        try buildGraph(format: format)
    }

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
        graphFormat = format
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

    /// Rebuilds on a fresh engine and resumes where it was. Used when the
    /// output device changes and when the band count does.
    private func rebuildGraph() {
        guard let format = graphFormat else { return }
        let wasState = state
        let first = segments.first
        let frame = wasState == .stopped ? 0 : currentFrame()

        session += 1
        removeMeterTap()
        player.stop()
        engine.stop()

        do {
            try buildGraph(format: format)
            if wasState != .stopped, let first {
                resume(segment: first, at: frame, playing: wasState == .playing)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Playback failed: \(error.localizedDescription)"
            finish()
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

    private static func makeInfo(for file: AVAudioFile, item: QueueItem) -> TrackInfo {
        let url = item.url
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
            title: item.title,
            artist: item.artist,
            album: item.album,
            artwork: nil,
            codec: codec,
            sampleRate: rate,
            bitDepth: depth > 0 && lossless ? depth : nil,
            channels: Int(file.processingFormat.channelCount),
            isLossless: lossless,
            duration: rate > 0 ? Double(file.length) / rate : 0
        )
    }

    /// Cover art, plus tags the queue has not loaded yet, once they load. The
    /// queue's own title stands in until then.
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
            self.timelineChanged.send()
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
