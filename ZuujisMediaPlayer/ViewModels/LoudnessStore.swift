// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import Combine

/// Loudness matching for the file player: what each song's tags say, what this
/// app has measured for songs without tags, and the settings that turn those
/// into a gain.
///
/// Nothing is ever written to a music file. Tags and measurements are cached
/// in Application Support `loudness.json`, keyed by path with the file's size
/// and modification time, so a changed file is read again.
///
/// The player asks `gain(for:)` as a song is scheduled. A measurement that
/// arrives while a song plays does not change that song: it is used from the
/// song's next start, so the volume never moves mid-song.
@MainActor
final class LoudnessStore: ObservableObject {

    // MARK: - Settings

    @Published var mode: LoudnessMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode); settingsChanged.send() }
    }
    /// Lower a song's gain so its own peak stays under full scale.
    @Published var preventClipping: Bool {
        didSet { UserDefaults.standard.set(preventClipping, forKey: Keys.preventClipping); settingsChanged.send() }
    }
    /// The gain for a song that has no tags and has not been measured yet.
    @Published var fallbackDB: Double {
        didSet { UserDefaults.standard.set(fallbackDB, forKey: Keys.fallback); settingsChanged.send() }
    }
    /// Measure songs without tags as they come up in the queue.
    @Published var measuresAutomatically: Bool {
        didSet { UserDefaults.standard.set(measuresAutomatically, forKey: Keys.automatic) }
    }

    static let fallbackRange = -12.0...0.0

    private enum Keys {
        static let mode = "loudnessMode"
        static let preventClipping = "loudnessPreventClipping"
        static let fallback = "loudnessFallbackDB"
        static let automatic = "loudnessMeasureAutomatically"
    }

    /// Fires when a setting that changes the gain does; the player re-reads it.
    let settingsChanged = PassthroughSubject<Void, Never>()

    var settings: LoudnessSettings {
        LoudnessSettings(mode: mode, fallbackDB: fallbackDB, preventClipping: preventClipping)
    }

    // MARK: - What is known

    struct Entry: Codable, Equatable, Sendable {
        var size: Int64
        var modified: Date
        var tags = ReplayGainInfo()
        /// Measured here: LUFS, linear sample peak, seconds.
        var lufs: Double?
        var peak: Double?
        var duration: Double?
        /// "artist␟album"; see `ReplayGainTags.albumKey`.
        var album: String?

        /// The loudness to count this song at within its album.
        var effectiveLUFS: Double? { lufs ?? tags.trackGain.map { Loudness.targetLUFS - $0 } }
        var needsMeasuring: Bool { tags.trackGain == nil && lufs == nil }
    }

    private var entries: [String: Entry] = [:]
    /// Album key to the paths known to belong to it.
    private var albums: [String: Set<String>] = [:]
    /// Paths whose size and date were compared with the file during this run.
    private var checked = Set<String>()

    let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        let defaults = UserDefaults.standard
        mode = LoudnessMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .album
        preventClipping = defaults.object(forKey: Keys.preventClipping) as? Bool ?? true
        let fallback = defaults.object(forKey: Keys.fallback) as? Double ?? -6
        fallbackDB = min(Self.fallbackRange.upperBound, max(Self.fallbackRange.lowerBound, fallback))
        measuresAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        self.fileURL = fileURL ?? AppPaths.support.appendingPathComponent("loudness.json")
        if let saved = SavedFile.load(Saved.self, from: self.fileURL, label: "loudness measurements") {
            entries = saved.entries
            for (path, entry) in entries { if let album = entry.album { albums[album, default: []].insert(path) } }
        }
    }

    /// The gain, in dB, `url` should play at now. Reads the file's tags the
    /// first time it is asked about a file (the tag area only, a few
    /// kilobytes); after that it answers from memory.
    func gain(for url: URL, artist: String?, album: String?) -> Double {
        guard mode != .off else { return 0 }
        return Loudness.gain(for: facts(for: url, artist: artist, album: album), settings: settings)
    }

    func facts(for url: URL, artist: String? = nil, album: String? = nil) -> LoudnessFacts {
        let entry = entry(for: url, fallbackAlbum: ReplayGainTags.albumKey(artist: artist, album: album))
        var facts = LoudnessFacts(tags: entry.tags, measuredLUFS: entry.lufs, measuredPeak: entry.peak)
        // An album figure only for a song that is itself part of it: a song
        // nothing is known about must not borrow a quiet neighbour's boost.
        if entry.tags.albumGain == nil, entry.effectiveLUFS != nil, let key = entry.album, let paths = albums[key] {
            let songs = paths.compactMap { entries[$0] }
            facts.albumLUFS = Loudness.albumLoudness(songs.compactMap { song in
                song.effectiveLUFS.map { ($0, song.duration ?? 0) }
            })
            // A peak is only a safe ceiling for the album if every song has one.
            let peaks = songs.map { $0.peak ?? $0.tags.trackPeak }
            if !peaks.contains(where: { $0 == nil }) { facts.albumPeak = peaks.compactMap { $0 }.max() }
        }
        return facts
    }

    private func entry(for url: URL, fallbackAlbum: String?) -> Entry {
        let path = url.path
        if checked.contains(path), var known = entries[path] {
            if known.album == nil, let fallbackAlbum {
                known.album = fallbackAlbum
                store(known, for: path)
            }
            return known
        }
        var fresh = Self.loadEntry(url, cached: entries[path])
        if fresh.album == nil { fresh.album = fallbackAlbum }
        checked.insert(path)
        if fresh != entries[path] { store(fresh, for: path) }
        return fresh
    }

    private func store(_ entry: Entry, for path: String) {
        if let old = entries[path]?.album, old != entry.album { albums[old]?.remove(path) }
        entries[path] = entry
        if let album = entry.album { albums[album, default: []].insert(path) }
        scheduleSave()
    }

    /// The cached entry if the file has not changed, else a new one with the
    /// file's tags and no measurement.
    private nonisolated static func loadEntry(_ url: URL, cached: Entry?) -> Entry {
        // A URL remembers the size and date it was last asked for; ask the disk.
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate ?? .distantPast
        if let cached, cached.size == size, cached.modified == modified { return cached }
        let read = ReplayGainTags.read(url)
        return Entry(size: size, modified: modified, tags: read.info, album: read.album ?? cached?.album)
    }

    // MARK: - Measuring

    struct Measurement: Sendable {
        var lufs: Double?
        var peak: Double
        var duration: Double
    }

    /// Decodes the whole file and measures it. Runs off the main thread.
    nonisolated static func measure(_ url: URL) -> Measurement? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard format.channelCount > 0, file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return nil }
        var meter = LoudnessMeter(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        while file.framePosition < file.length {
            if Task.isCancelled { return nil }
            do { try file.read(into: buffer) } catch { break }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            meter.add(data, frames: Int(buffer.frameLength))
        }
        guard meter.duration > 0 else { return nil }
        return Measurement(lufs: meter.integrated, peak: Double(meter.peak), duration: meter.duration)
    }

    private enum Outcome: Sendable { case known, measured, failed }

    /// Brings one file's entry up to date and measures it if it has no gain.
    private func bringUpToDate(_ url: URL, albumHint: String?) async -> Outcome {
        let path = url.path
        if checked.contains(path), let known = entries[path], !known.needsMeasuring { return .known }
        let cached = entries[path]
        let result: (Entry, Bool)? = await Task.detached(priority: .utility) {
            var entry = Self.loadEntry(url, cached: cached)
            guard entry.needsMeasuring else { return (entry, false) }
            guard let measured = Self.measure(url) else { return nil }
            // A silent file has no loudness; -70 keeps it from being measured again.
            entry.lufs = measured.lufs ?? -70
            entry.peak = measured.peak
            entry.duration = measured.duration
            return (entry, true)
        }.value
        guard let (loaded, measured) = result else { return .failed }
        var entry = loaded
        if entry.album == nil { entry.album = albumHint }
        checked.insert(path)
        if entry != entries[path] { store(entry, for: path) }
        return measured ? .measured : .known
    }

    // Songs coming up in the queue, measured one at a time in the background.
    private var ahead: [(url: URL, album: String?)] = []
    private var aheadTask: Task<Void, Never>?

    /// Measures these songs if they have no tags and no measurement yet. The
    /// player calls it with the playing song, the next one and the rest of the
    /// playing album.
    func measureAhead(_ songs: [(url: URL, artist: String?, album: String?)]) {
        guard mode != .off, measuresAutomatically, batchTask == nil else { return }
        for song in songs where !ahead.contains(where: { $0.url == song.url }) {
            if checked.contains(song.url.path), entries[song.url.path]?.needsMeasuring == false { continue }
            ahead.append((song.url, ReplayGainTags.albumKey(artist: song.artist, album: song.album)))
        }
        guard aheadTask == nil, !ahead.isEmpty else { return }
        aheadTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.ahead.isEmpty {
                let next = self.ahead.removeFirst()
                _ = await self.bringUpToDate(next.url, albumHint: next.album)
            }
            self?.aheadTask = nil
        }
    }

    // MARK: - Batch

    /// Progress of "Measure Loudness for …", or its result for a few seconds.
    @Published private(set) var batchStatus: String?
    @Published private(set) var isMeasuringBatch = false
    private var batchTask: Task<Void, Never>?

    /// Measures every one of `songs` that has no ReplayGain tags and has not
    /// been measured. Songs already done are skipped, so a stopped run resumes.
    func measure(_ songs: [(url: URL, artist: String?, album: String?)], label: String) {
        guard batchTask == nil, !songs.isEmpty else { return }
        aheadTask?.cancel()
        aheadTask = nil
        ahead = []
        isMeasuringBatch = true
        batchStatus = "Measuring loudness: starting…"
        let width = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

        batchTask = Task { [weak self] in
            var measured = 0, known = 0, failed = 0, done = 0
            var iterator = songs.makeIterator()
            await withTaskGroup(of: Outcome.self) { group in
                func next() {
                    guard !Task.isCancelled, let song = iterator.next() else { return }
                    let hint = ReplayGainTags.albumKey(artist: song.artist, album: song.album)
                    group.addTask { await self?.bringUpToDate(song.url, albumHint: hint) ?? .failed }
                }
                for _ in 0..<width { next() }
                for await outcome in group {
                    switch outcome {
                    case .measured: measured += 1
                    case .known: known += 1
                    case .failed: failed += 1
                    }
                    done += 1
                    if !Task.isCancelled {
                        self?.batchStatus = "Measuring loudness: \(done) of \(songs.count)"
                    }
                    next()
                }
            }
            guard let self else { return }
            let stopped = Task.isCancelled ? "Stopped. " : ""
            self.batchStatus = "\(stopped)\(label): \(measured) measured, \(known) already known"
                + (failed > 0 ? ", \(failed) could not be read" : "")
            self.isMeasuringBatch = false
            self.batchTask = nil
            self.saveNow()
            // Long enough to be seen after a run that finished unwatched.
            try? await Task.sleep(for: .seconds(60))
            if self.batchTask == nil { self.batchStatus = nil }
        }
    }

    func stopMeasuring() {
        batchTask?.cancel()
    }

    // MARK: - Persistence

    private struct Saved: Codable {
        var entries: [String: Entry]
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        SavedFile.save(Saved(entries: entries), to: fileURL, label: "loudness measurements")
    }
}
