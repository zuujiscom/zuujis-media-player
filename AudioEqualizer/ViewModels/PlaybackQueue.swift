// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation

struct QueueItem: Identifiable, Codable, Equatable {
    let id: UUID
    var url: URL
    var title: String
    var artist: String?
    var album: String?
    /// Seconds; nil until the file's metadata has loaded.
    var duration: Double?

    init(url: URL) {
        id = UUID()
        self.url = url
        title = url.deletingPathExtension().lastPathComponent
    }
}

/// The play list, its play order and the position in it.
///
/// This knows nothing about audio: `PlayerEngine` asks it what comes next and
/// tells it what is playing. It is persisted, so the list survives a relaunch.
@MainActor
final class PlaybackQueue: ObservableObject {

    enum Repeat: String, Codable, CaseIterable {
        case off, all, one

        var next: Repeat {
            switch self {
            case .off: return .all
            case .all: return .one
            case .one: return .off
            }
        }
    }

    @Published private(set) var items: [QueueItem] = [] { didSet { itemsChanged() } }
    @Published private(set) var currentID: QueueItem.ID?
    @Published var shuffle = false {
        didSet {
            // Turning it on deals a fresh order (current item first); turning
            // it off falls back to list order.
            order = []
            rebuildOrder()
            scheduleSave()
        }
    }
    @Published var repeatMode: Repeat = .off { didSet { scheduleSave() } }

    /// Item ids in the order they will play.
    private var order: [QueueItem.ID] = []
    private var saveTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?

    /// Everything `AVAudioFile` decodes natively.
    static let audioExtensions = LibraryModel.audioExtensions

    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = support.appendingPathComponent("AudioEqualizer", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("queue.json")
        }
        load()
    }

    // MARK: - Reading

    var current: QueueItem? { item(withID: currentID) }

    func item(withID id: QueueItem.ID?) -> QueueItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    private var orderPosition: Int? {
        guard let currentID else { return nil }
        return order.firstIndex(of: currentID)
    }

    /// What plays after the current item when it ends on its own — the answer
    /// the engine pre-schedules for gapless playback. `nil` means the queue ends.
    func itemAfterCurrent() -> QueueItem? {
        guard !order.isEmpty else { return nil }
        if repeatMode == .one, let current { return current }
        guard let pos = orderPosition else { return item(withID: order.first) }
        if pos + 1 < order.count { return item(withID: order[pos + 1]) }
        return repeatMode == .all ? item(withID: order.first) : nil
    }

    /// What the Next button goes to: like `itemAfterCurrent`, but "repeat one"
    /// does not trap the user on the same track.
    func itemForSkipForward() -> QueueItem? {
        guard !order.isEmpty else { return nil }
        guard let pos = orderPosition else { return item(withID: order.first) }
        if pos + 1 < order.count { return item(withID: order[pos + 1]) }
        return repeatMode == .off ? nil : item(withID: order.first)
    }

    func itemForSkipBack() -> QueueItem? {
        guard !order.isEmpty, let pos = orderPosition else { return nil }
        if pos > 0 { return item(withID: order[pos - 1]) }
        return repeatMode == .off ? nil : item(withID: order.last)
    }

    // MARK: - Editing

    func setCurrent(_ id: QueueItem.ID?) {
        guard currentID != id else { return }
        // The shuffled order is one fixed permutation: jumping into the middle of
        // it carries on from there rather than dealing again.
        currentID = id
        scheduleSave()
    }

    /// Adds files and, for folders, every audio file beneath them. Returns what
    /// was added, in play order.
    @discardableResult
    func add(urls: [URL], replacing: Bool = false) -> [QueueItem] {
        let files = Self.audioFiles(in: urls)
        let added = files.map { QueueItem(url: $0) }
        if replacing {
            currentID = nil
            items = added
        } else {
            items.append(contentsOf: added)
        }
        loadMetadata(for: added.map(\.id))
        scheduleSave()
        return added
    }

    func remove(_ ids: Set<QueueItem.ID>) {
        guard !ids.isEmpty else { return }
        if let currentID, ids.contains(currentID) {
            // Land on what followed it, so playback does not jump to the top.
            self.currentID = itemForSkipForward().flatMap { ids.contains($0.id) ? nil : $0.id }
        }
        items.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func clear() {
        currentID = nil
        items = []
        scheduleSave()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        // The same semantics as SwiftUI's `move(fromOffsets:toOffset:)`, without
        // making this model depend on SwiftUI.
        let moving = source.sorted().map { items[$0] }
        let shift = source.filter { $0 < destination }.count
        var rest = items
        for index in source.sorted(by: >) { rest.remove(at: index) }
        rest.insert(contentsOf: moving, at: max(0, min(rest.count, destination - shift)))
        items = rest
        scheduleSave()
    }

    // MARK: - Order

    /// Tag loading rewrites items constantly; the order only cares when the set
    /// of ids moves.
    private var orderedIDs: [QueueItem.ID] = []

    private func itemsChanged() {
        let ids = items.map(\.id)
        guard ids != orderedIDs else { return }
        orderedIDs = ids
        rebuildOrder()
    }

    private func rebuildOrder() {
        let ids = items.map(\.id)
        guard shuffle else {
            order = ids
            return
        }
        // Keep the existing relative order for ids that were already in it, so
        // a metadata update or a removal does not reshuffle what is coming.
        let known = Set(ids)
        let kept = order.filter { known.contains($0) }
        let keptSet = Set(kept)
        let fresh = ids.filter { !keptSet.contains($0) }.shuffled()

        if kept.isEmpty || (fresh.count == ids.count) {
            var all = ids.shuffled()
            if let currentID, let i = all.firstIndex(of: currentID) { all.swapAt(0, i) }
            order = all
            return
        }
        // New items join after the current one, in random places.
        var merged = kept
        for id in fresh {
            let low = (currentID.flatMap { merged.firstIndex(of: $0) } ?? -1) + 1
            merged.insert(id, at: Int.random(in: low...merged.count))
        }
        order = merged
    }

    // MARK: - Files

    /// Expands folders and filters to audio, sorted the way Finder sorts.
    static func audioFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let walker = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                var found: [URL] = []
                for case let file as URL in walker where audioExtensions.contains(file.pathExtension.lowercased()) {
                    found.append(file)
                }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                result.append(contentsOf: found)
            } else if audioExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }

    // MARK: - Metadata

    /// Fills in tags and durations a few files at a time, without blocking the
    /// list: items appear at once with their file names.
    private func loadMetadata(for ids: [QueueItem.ID]) {
        let targets = ids.compactMap { id in item(withID: id).map { ($0.id, $0.url) } }
        guard !targets.isEmpty else { return }

        let previous = metadataTask
        metadataTask = Task { [weak self] in
            await previous?.value
            var iterator = targets.makeIterator()
            await withTaskGroup(of: (QueueItem.ID, TrackMetadata).self) { group in
                func next() { if let (id, url) = iterator.next() { group.addTask { (id, await TrackMetadata.read(url)) } } }
                for _ in 0..<4 { next() }
                for await (id, meta) in group {
                    self?.apply(meta, to: id)
                    next()
                }
            }
        }
    }

    private func apply(_ meta: TrackMetadata, to id: QueueItem.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[i]
        if let title = meta.title, !title.isEmpty { item.title = title }
        item.artist = meta.artist
        item.album = meta.album
        item.duration = meta.duration
        if item != items[i] { items[i] = item }
    }

    // MARK: - Persistence

    private struct Saved: Codable {
        var items: [QueueItem]
        var currentID: QueueItem.ID?
        var shuffle: Bool
        var repeatMode: Repeat
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        // Assign the backing stores directly: the observers would each queue a
        // save of a half-restored state.
        _items = Published(initialValue: saved.items)
        _shuffle = Published(initialValue: saved.shuffle)
        _repeatMode = Published(initialValue: saved.repeatMode)
        orderedIDs = saved.items.map(\.id)
        order = orderedIDs
        if saved.shuffle { order = []; rebuildOrder() }
        if let id = saved.currentID, saved.items.contains(where: { $0.id == id }) { currentID = id }
        // Items saved before their tags finished loading (or before FLAC tags were
        // readable) get another go.
        loadMetadata(for: saved.items.filter { $0.duration == nil || ($0.artist == nil && $0.album == nil) }.map(\.id))
    }

    /// Debounced: a folder import mutates the list hundreds of times as tags
    /// arrive, and one write at the end is enough.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let saved = Saved(items: items, currentID: currentID, shuffle: shuffle, repeatMode: repeatMode)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Tags and duration for one file. FLAC's Vorbis comments are read directly
/// (AVFoundation plays FLAC but ignores them); everything else goes through
/// AVFoundation's metadata.
struct TrackMetadata: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var duration: Double?

    static func read(_ url: URL) async -> TrackMetadata {
        var meta = TrackMetadata()
        let asset = AVURLAsset(url: url)

        if url.pathExtension.lowercased() == "flac", let tags = FLACTags.read(url) {
            meta.title = tags["TITLE"]
            // Album artist first: it keeps a compilation's tracks on one album.
            meta.artist = tags["ALBUMARTIST"] ?? tags["ALBUM ARTIST"] ?? tags["ALBUM_ARTIST"] ?? tags["ARTIST"]
            meta.album = tags["ALBUM"]
            meta.genre = tags["GENRE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            meta.trackNumber = LibraryModel.leadingNumber(tags["TRACKNUMBER"] ?? tags["TRACK"])
            meta.discNumber = LibraryModel.leadingNumber(tags["DISCNUMBER"] ?? tags["DISC"])
            meta.year = LibraryModel.year(from: tags["DATE"] ?? tags["YEAR"])
        } else {
            if let items = try? await asset.load(.commonMetadata) {
                func text(_ id: AVMetadataIdentifier) async -> String? {
                    guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
                    return try? await item.load(.stringValue)
                }
                meta.title = await text(.commonIdentifierTitle)
                meta.artist = await text(.commonIdentifierArtist)
                meta.album = await text(.commonIdentifierAlbumName)
                meta.genre = await text(.commonIdentifierType)
                meta.year = LibraryModel.year(from: await text(.commonIdentifierCreationDate))
            }
            if let all = try? await asset.load(.metadata) {
                // The common "creation date" is often empty for MP3: ask for the
                // ID3 year (TYER, v2.3) and recording time (TDRC, v2.4) directly.
                if meta.year == nil {
                    for id in [AVMetadataIdentifier.id3MetadataYear, .id3MetadataRecordingTime, .id3MetadataOriginalReleaseYear] {
                        if let item = AVMetadataItem.metadataItems(from: all, filteredByIdentifier: id).first,
                           let year = LibraryModel.year(from: try? await item.load(.stringValue)) {
                            meta.year = year
                            break
                        }
                    }
                }
                if let item = AVMetadataItem.metadataItems(from: all, filteredByIdentifier: .id3MetadataTrackNumber).first {
                    meta.trackNumber = LibraryModel.leadingNumber(try? await item.load(.stringValue))
                }
                if let item = AVMetadataItem.metadataItems(from: all, filteredByIdentifier: .id3MetadataPartOfASet).first {
                    meta.discNumber = LibraryModel.leadingNumber(try? await item.load(.stringValue))
                }
            }
        }

        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            meta.duration = duration.seconds
        }
        return meta
    }
}
