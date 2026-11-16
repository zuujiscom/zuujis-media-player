// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import Combine

/// The music library: folders the user has added, and every audio file in
/// them with its tags, persisted to Application Support `library.json`.
///
/// A rescan walks the folders and re-reads tags only for files that are new
/// or whose size or modification time changed, so launching with a large
/// library is a stat per file. A folder whose drive is not connected keeps
/// its tracks in the list (marked offline) instead of losing them.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var folders: [URL] = []
    @Published private(set) var tracks: [LibraryTrack] = []
    /// Tag edits by file path, laid over what the files say.
    private(set) var edits: [String: TagEdit] = [:]
    @Published private(set) var offlineFolders: Set<URL> = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanDone = 0
    @Published private(set) var scanTotal = 0
    @Published private(set) var isWriting = false
    /// Set when writing tags to files did not fully succeed; the UI shows and clears it.
    @Published var writeReport: String?
    /// What the last finished scan did, for the library's status line.
    @Published private(set) var lastScan: ScanSummary?

    struct ScanSummary: Equatable, Sendable {
        /// New or changed files whose tags were read.
        var read = 0
        /// Songs that were in the library and are no longer on disk.
        var removed = 0
        /// Songs kept from folders that could not be reached.
        var keptOffline = 0
        /// Files in the folders that are not a supported audio format.
        var skipped = 0
        var skippedExtensions: [String: Int] = [:]

        /// One line for the status bar; nil when there is nothing to say.
        var text: String? {
            var parts: [String] = []
            if read > 0 { parts.append("\(read) new or changed") }
            if removed > 0 { parts.append("\(removed) removed") }
            if skipped > 0 { parts.append("\(skipped) other file\(skipped == 1 ? "" : "s") skipped") }
            return parts.isEmpty ? nil : "Last scan: " + parts.joined(separator: ", ")
        }

        /// The longer explanation shown on hover.
        var detail: String {
            var lines: [String] = []
            lines.append("Tags read for \(read) new or changed song\(read == 1 ? "" : "s").")
            if removed > 0 { lines.append("\(removed) song\(removed == 1 ? " was" : "s were") no longer on disk and left the library.") }
            if keptOffline > 0 { lines.append("\(keptOffline) song\(keptOffline == 1 ? " is" : "s are") kept from folders that could not be reached; they return when the drive is connected.") }
            if skipped > 0 {
                let kinds = skippedExtensions.sorted { $0.value > $1.value }.prefix(6)
                    .map { "\($0.key.isEmpty ? "no extension" : "." + $0.key) (\($0.value))" }
                    .joined(separator: ", ")
                lines.append("\(skipped) file\(skipped == 1 ? " was" : "s were") skipped because the format is not supported: \(kinds).")
            }
            return lines.joined(separator: "\n")
        }
    }

    let fileURL: URL
    private var scanTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppPaths.support.appendingPathComponent("library.json")
        }
        load()
        if !folders.isEmpty { rescan() }
    }

    // MARK: - Folders

    func addFolders(_ urls: [URL]) {
        var added = false
        for url in urls.map(\.standardizedFileURL) where !folders.contains(url) {
            folders.append(url)
            added = true
        }
        guard added else { return }
        scheduleSave()
        rescan()
    }

    /// Whether `path` lies inside `folder`. Enumeration reports `/private/var/...`
    /// for a folder that was added as `/var/...` (likewise `/tmp`, `/etc`), so
    /// the comparison ignores a leading `/private`.
    nonisolated static func folder(_ folder: URL, contains path: String) -> Bool {
        func plain(_ p: String) -> String { p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p }
        return plain(path).hasPrefix(plain(folder.path) + "/")
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        // Keep what another folder still covers.
        let remaining = folders
        tracks.removeAll { track in
            Self.folder(url, contains: track.url.path) && !remaining.contains { Self.folder($0, contains: track.url.path) }
        }
        offlineFolders.remove(url)
        scheduleSave()
        rescan()
    }

    // MARK: - Scanning

    private struct FileInfo: Sendable {
        var url: URL
        var size: Int64
        var modified: Date
    }

    private struct Listing: Sendable {
        var folder: URL
        var online: Bool
        var files: [FileInfo]
        var skipped: [String: Int] = [:]
    }

    func rescan() {
        scanTask?.cancel()
        guard !folders.isEmpty else {
            tracks = []
            isScanning = false
            return
        }
        isScanning = true
        scanDone = 0
        scanTotal = 0
        let folders = self.folders
        let cache = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        scanTask = Task { [weak self] in
            let listing = await Task.detached(priority: .utility) { Self.enumerate(folders) }.value
            guard !Task.isCancelled, let self else { return }

            var kept: [String: LibraryTrack] = [:]
            var pending: [FileInfo] = []
            var offline = Set<URL>()
            var summary = ScanSummary()
            for entry in listing {
                if !entry.online {
                    offline.insert(entry.folder)
                    for (id, track) in cache where Self.folder(entry.folder, contains: id) {
                        if kept[id] == nil { summary.keptOffline += 1 }
                        kept[id] = track
                    }
                    continue
                }
                for (ext, n) in entry.skipped {
                    summary.skippedExtensions[ext, default: 0] += n
                    summary.skipped += n
                }
                for file in entry.files where kept[file.url.path] == nil {
                    if let hit = cache[file.url.path], hit.size == file.size, hit.modified == file.modified {
                        kept[file.url.path] = hit
                    } else if !pending.contains(where: { $0.url == file.url }) {
                        pending.append(file)
                    }
                }
            }
            let pendingIDs = Set(pending.map(\.url.path))
            summary.removed = cache.keys.filter { kept[$0] == nil && !pendingIDs.contains($0) }.count
            summary.read = pending.count
            self.offlineFolders = offline
            self.tracks = Array(kept.values)
            self.scanTotal = pending.count

            // Tags for new and changed files, four at a time, published in
            // batches so a big first scan fills the list as it goes.
            var iterator = pending.makeIterator()
            var batch: [LibraryTrack] = []
            await withTaskGroup(of: LibraryTrack.self) { group in
                func next() { if let file = iterator.next() { group.addTask { await Self.readTrack(file) } } }
                for _ in 0..<4 { next() }
                for await track in group {
                    guard !Task.isCancelled else { group.cancelAll(); break }
                    batch.append(track)
                    self.scanDone += 1
                    if batch.count >= 40 { self.merge(batch); batch = [] }
                    next()
                }
            }
            guard !Task.isCancelled else { return }
            self.merge(batch)
            self.lastScan = summary
            self.isScanning = false
            self.scheduleSave()
        }
    }

    private func merge(_ batch: [LibraryTrack]) {
        guard !batch.isEmpty else { return }
        var byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for track in batch { byID[track.id] = edits[track.id]?.apply(to: track) ?? track }
        tracks = Array(byID.values)
        scheduleSave()
    }

    /// Walks each folder off the main thread. A folder that is missing (an
    /// unplugged drive) is reported offline rather than empty.
    private nonisolated static func enumerate(_ folders: [URL]) -> [Listing] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        return folders.map { folder in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let walker = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                return Listing(folder: folder, online: false, files: [])
            }
            var files: [FileInfo] = []
            var skipped: [String: Int] = [:]
            for case let url as URL in walker {
                let ext = url.pathExtension.lowercased()
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard LibraryModel.audioExtensions.contains(ext) else {
                    // Only regular files count: folders are walked into, and
                    // artwork and playlists beside the music are expected.
                    if values?.isRegularFile == true, !LibraryScan.expectedCompanions.contains(ext) {
                        skipped[ext, default: 0] += 1
                    }
                    continue
                }
                files.append(FileInfo(url: url, size: Int64(values?.fileSize ?? 0),
                                      modified: values?.contentModificationDate ?? .distantPast))
            }
            return Listing(folder: folder, online: true, files: files, skipped: skipped)
        }
    }

    private nonisolated static func readTrack(_ file: FileInfo) async -> LibraryTrack {
        let meta = await TrackMetadata.read(file.url)
        let name = file.url.deletingPathExtension().lastPathComponent
        return LibraryTrack(
            url: file.url,
            title: (meta.title?.isEmpty == false ? meta.title : nil) ?? LibraryModel.title(fromFilename: file.url),
            artist: meta.artist,
            album: meta.album,
            genre: meta.genre,
            trackNumber: meta.trackNumber ?? LibraryModel.trackNumber(fromFilename: name),
            discNumber: meta.discNumber,
            year: meta.year,
            duration: meta.duration,
            size: file.size,
            modified: file.modified)
    }

    // MARK: - Editing

    /// Applies `edit` to every one of `targets`: at once in the library, then,
    /// with `writeToFiles`, into the audio files (FLAC and MP3). A file that
    /// takes the change no longer needs an override; one that cannot (another
    /// format, a read-only or unplugged drive) keeps it in the library only.
    func apply(_ edit: TagEdit, to targets: [LibraryTrack], writeToFiles: Bool = false) {
        guard !edit.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        for id in ids { edits[id] = (edits[id] ?? TagEdit()).merged(with: edit) }
        tracks = tracks.map { ids.contains($0.id) ? edit.apply(to: $0) : $0 }
        scheduleSave()
        guard writeToFiles else { return }

        let jobs = targets.compactMap { track in edits[track.id].map { (track.url, track.id, $0) } }
        var unsupported = 0
        isWriting = true
        Task { [weak self] in
            var written = 0
            var failures: [String] = []
            for (url, id, merged) in jobs {
                guard TagWriter.canWrite(url) else { unsupported += 1; continue }
                let result: Result<(Int64, Date), Error> = await Task.detached(priority: .userInitiated) {
                    Result {
                        try TagWriter.write(merged, to: url)
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        return (Int64(values.fileSize ?? 0), values.contentModificationDate ?? Date())
                    }
                }.value
                guard let self else { return }
                switch result {
                case .success(let (size, modified)):
                    written += 1
                    self.edits[id] = nil
                    // The file changed on purpose: keep the cache entry valid.
                    if let i = self.tracks.firstIndex(where: { $0.id == id }) {
                        self.tracks[i].size = size
                        self.tracks[i].modified = modified
                    }
                case .failure(let error):
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            guard let self else { return }
            self.isWriting = false
            self.scheduleSave()
            if !failures.isEmpty || unsupported > 0 {
                var lines = ["Saved to \(written) of \(jobs.count) files."]
                if unsupported > 0 { lines.append("\(unsupported) are not FLAC or MP3, so their changes are kept in the library only.") }
                lines += failures.prefix(5).map { "Could not write " + $0 }
                if failures.count > 5 { lines.append("…and \(failures.count - 5) more.") }
                self.writeReport = lines.joined(separator: "\n")
            }
        }
    }

    func isEdited(_ track: LibraryTrack) -> Bool { edits[track.id] != nil }

    /// Drops the edits on `targets` and reads their tags from the files again.
    func resetEdits(for targets: [LibraryTrack]) {
        let reset = targets.filter { edits[$0.id] != nil }
        guard !reset.isEmpty else { return }
        for track in reset { edits[track.id] = nil }
        scheduleSave()
        Task { [weak self] in
            for track in reset {
                let fresh = await Self.readTrack(FileInfo(url: track.url, size: track.size, modified: track.modified))
                self?.merge([fresh])
            }
        }
    }

    // MARK: - Persistence

    private struct Saved: Codable {
        var folders: [URL]
        var tracks: [LibraryTrack]
        var edits: [String: TagEdit]?
        /// 2 = tracks carry a genre; 3 = MP3 years are read from ID3. An older file is re-read once to fill it in.
        var schema: Int?
    }

    private static let schema = 3

    private func load() {
        guard let saved = SavedFile.load(Saved.self, from: fileURL, label: "library") else { return }
        folders = saved.folders
        tracks = saved.tracks
        edits = saved.edits ?? [:]
        // Library files from before genres existed: a size that cannot match
        // makes the next scan re-read every file's tags once.
        if (saved.schema ?? 1) < Self.schema {
            for i in tracks.indices { tracks[i].size = -1 }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        SavedFile.save(Saved(folders: folders, tracks: tracks, edits: edits, schema: Self.schema), to: fileURL, label: "library")
    }
}

enum LibraryScan {
    /// Files that normally sit beside music and are not worth reporting as skipped.
    static let expectedCompanions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff",
        "m3u", "m3u8", "pls", "cue", "log", "txt", "nfo", "pdf", "sfv", "md5", "accurip", "lrc", "db", "ini",
    ]
}
