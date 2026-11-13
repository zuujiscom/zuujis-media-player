// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Combine
import Foundation

/// Finds the lyrics of whatever the player has loaded. By default everything
/// is read from the user's own files and nothing touches the network:
///
/// 1. a sidecar beside the song with the same name: `.lrc` (synced) or `.txt`;
/// 2. a FLAC's `LYRICS` / `UNSYNCEDLYRICS` Vorbis comment;
/// 3. MP3's USLT and M4A's ©lyr, which AVFoundation exposes.
///
/// 4. only if the user turns it on (or presses "Look up online" for one
///    song): LRCLIB (lrclib.net), a free lyrics database. That sends the
///    song's title, artist, album and length to lrclib.net, which is why it is
///    off by default. A hit is cached in Application Support (never beside
///    the music) so each song is asked about once.
///
/// Either source may hold LRC text, so each is run through `Lyrics.parse`.
@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var isLoading = false
    /// Which file `lyrics` belongs to; the view shows nothing stale.
    @Published private(set) var url: URL?

    /// Look songs up on LRCLIB automatically when nothing local is found.
    @Published var onlineLookup: Bool = UserDefaults.standard.bool(forKey: "lyricsOnlineLookup") {
        didSet {
            UserDefaults.standard.set(onlineLookup, forKey: "lyricsOnlineLookup")
            if onlineLookup, lyrics == nil, !isLoading, let track = currentTrack { load(track) }
        }
    }
    /// This song's sync adjustment in seconds: positive shows each line sooner
    /// (for lyrics that run late), negative later. Remembered per song.
    @Published private(set) var offset = 0.0
    private static let offsetsKey = "lyricsOffsets"

    /// Where in the lyrics' own timeline the listener is: the playback
    /// position, less the output latency (what is heard now was rendered a
    /// moment ago), plus the song's adjustment. Speed needs no term: the
    /// position counts source time.
    func time(for player: PlayerEngine) -> Double {
        player.currentTime() - player.outputLatency + offset
    }

    /// The same shift for a fixed instant, used for the widgets' line times.
    var shift: Double { offset }

    func nudge(by seconds: Double) {
        setOffset(((offset + seconds) * 10).rounded() / 10)
    }

    func resetOffset() { setOffset(0) }

    private func setOffset(_ value: Double) {
        offset = min(10, max(-10, value))
        guard let path = url?.path else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.offsetsKey) as? [String: Double] ?? [:]
        if offset == 0 { all[path] = nil } else { all[path] = offset }
        UserDefaults.standard.set(all, forKey: Self.offsetsKey)
    }

    /// Why the last online lookup found nothing, for the empty state.
    @Published private(set) var onlineMessage: String?

    private var cancellable: AnyCancellable?
    private var task: Task<Void, Never>?
    private var currentTrack: PlayerEngine.TrackInfo?
    /// Songs already asked about this run, so a miss is not repeated.
    private var missed = Set<URL>()

    func attach(to player: PlayerEngine) {
        guard cancellable == nil else { return }
        cancellable = player.$track
            .removeDuplicates { $0?.url == $1?.url }
            .sink { [weak self] track in self?.load(track) }
    }

    /// One-shot lookup for the current song, from the empty state's button.
    func lookUpNow() {
        guard let track = currentTrack else { return }
        load(track, forceOnline: true)
    }

    private func load(_ track: PlayerEngine.TrackInfo?, forceOnline: Bool = false) {
        task?.cancel()
        currentTrack = track
        url = track?.url
        offset = track.flatMap { (UserDefaults.standard.dictionary(forKey: Self.offsetsKey) as? [String: Double])?[$0.url.path] } ?? 0
        lyrics = nil
        onlineMessage = nil
        guard let track else { isLoading = false; return }
        isLoading = true
        let online = forceOnline || (onlineLookup && !missed.contains(track.url))
        task = Task { [weak self] in
            var found = await Self.find(for: track.url)
            var message: String?
            if found == nil, online {
                // The player's copy of the tags may still be loading.
                var asked = Query(track)
                let meta = await TrackMetadata.read(track.url)
                if let title = meta.title, !title.isEmpty { asked.title = title }
                asked.artist = meta.artist ?? track.artist
                asked.album = meta.album ?? track.album
                (found, message) = await Self.fetchOnline(asked)
            }
            guard !Task.isCancelled, let self, self.url == track.url else { return }
            // The title and artist can still be filling in from the tags; a
            // miss is remembered only for this run.
            if found == nil, online { self.missed.insert(track.url) }
            self.lyrics = found
            self.onlineMessage = message
            self.isLoading = false
        }
    }

    // MARK: Online (LRCLIB)

    private nonisolated static var cacheFolder: URL {
        let dir = AppPaths.support.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func cacheFile(forPath path: String) -> URL {
        // A stable name from the path; the file's contents are the lyrics.
        var hash: UInt64 = 5381
        for byte in path.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return cacheFolder.appendingPathComponent(String(hash, radix: 16) + ".lrc")
    }

    /// What a lookup needs about a song; also what the cache remembers, so saved
    /// lyrics can be checked again later without the song being loaded.
    struct Query: Codable {
        var path: String
        var title: String
        var artist: String?
        var album: String?
        var duration: Double

        init(_ track: PlayerEngine.TrackInfo) {
            path = track.url.path; title = track.title; artist = track.artist; album = track.album; duration = track.duration
        }
    }

    /// A song comes in several cuts (radio edit, album, extended) and LRCLIB
    /// keeps each one's own timing, so a synced version is only used when its
    /// length is close to the file's.
    private nonisolated static let lengthTolerance = 8.0
    /// Bumped when the choice of version changes, so older saves are refetched.
    private nonisolated static let cacheRevision = 2

    /// Asks lrclib.net for the song, preferring synced lyrics of the cut that
    /// matches this file's length. Returns the lyrics, or nil and a short reason.
    nonisolated static func fetchOnline(_ track: Query) async -> (Lyrics?, String?) {
        let cache = cacheFile(forPath: track.path)
        // The first line records the length of the cut the cache holds, so a
        // cache from a different cut (or an older build) is not trusted.
        if let cached = try? String(contentsOf: cache, encoding: .utf8),
           let first = cached.split(separator: "\n", maxSplits: 1).first, first.hasPrefix("[zmp-length:"),
           let length = Double(first.dropFirst(12).dropLast()),
           abs(length - track.duration) <= lengthTolerance,
           cached.contains("[zmp-rev:\(cacheRevision)]"),
           let lyrics = Lyrics.parse(cached) {
            return (lyrics, nil)
        }
        guard let artist = track.artist, !artist.isEmpty, !track.title.isEmpty else {
            return (nil, "Needs a title and artist in the tags.")
        }

        func request(_ path: String, _ items: [URLQueryItem]) async -> Any? {
            var parts = URLComponents(string: "https://lrclib.net/api/\(path)")!
            parts.queryItems = items
            guard let url = parts.url else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("ZuujisMediaPlayer (https://github.com/zuujiscom/zuujis-media-player)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }

        // Every candidate: the exact match first, then everything LRCLIB has for
        // this title and artist.
        var candidates: [[String: Any]] = []
        if let exact = await request("get", [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: track.album ?? ""),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
        ]) as? [String: Any] { candidates.append(exact) }
        if let found = await request("search", [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: artist),
        ]) as? [[String: Any]] { candidates += found }
        if candidates.isEmpty { return (nil, "Not found on LRCLIB.") }

        func length(_ c: [String: Any]) -> Double { (c["duration"] as? Double) ?? (c["duration"] as? Int).map(Double.init) ?? 0 }
        func synced(_ c: [String: Any]) -> String? { (c["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 } }

        // Among synced candidates of about this length, the one for this
        // file's own album first (a compilation's entry is often a re-labelled
        // radio edit with different timing), then the nearest length.
        func norm(_ text: String?) -> String {
            (text ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let album = norm(track.album)
        func fromThisAlbum(_ c: [String: Any]) -> Bool {
            let other = norm(c["albumName"] as? String)
            return !album.isEmpty && !other.isEmpty && (other.contains(album) || album.contains(other))
        }
        // Timing is the thing that differs between entries, and LRCLIB has many
        // near-duplicates (a radio edit's timing copied onto compilations, a
        // stray one-off). So group the candidates by where their first line
        // falls and how many lines they have, and take the group most entries
        // agree on; within it, the same album, then the nearest length.
        func firstTime(_ c: [String: Any]) -> Double {
            guard let text = synced(c), let first = Lyrics.parse(text)?.lines.first?.time else { return -100 }
            return first
        }
        func lineCount(_ c: [String: Any]) -> Int { Lyrics.parse(synced(c) ?? "")?.lines.count ?? 0 }
        var seen = Set<Int>()
        let usable = candidates.filter { c in
            guard synced(c) != nil, abs(length(c) - track.duration) <= lengthTolerance else { return false }
            if let id = c["id"] as? Int { return seen.insert(id).inserted }
            return true
        }
        func sameTiming(_ a: [String: Any], _ b: [String: Any]) -> Bool {
            abs(firstTime(a) - firstTime(b)) <= 1.0 && abs(lineCount(a) - lineCount(b)) <= 2
        }
        let best = usable.max { a, b in
            let (ca, cb) = (usable.filter { sameTiming($0, a) }.count, usable.filter { sameTiming($0, b) }.count)
            if ca != cb { return ca < cb }
            let (aa, ab) = (fromThisAlbum(a), fromThisAlbum(b))
            if aa != ab { return !aa }
            return abs(length(a) - track.duration) > abs(length(b) - track.duration)
        }
        if let best, let text = synced(best), Lyrics.parse(text) != nil {
            let meta = (try? JSONEncoder().encode(track))?.base64EncodedString() ?? ""
            let stored = "[zmp-length:\(Int(length(best).rounded()))]\n[zmp-rev:\(cacheRevision)]\n[zmp-meta:\(meta)]\n" + text
            try? stored.write(to: cache, atomically: true, encoding: .utf8)
            return (Lyrics.parse(text), nil)
        }

        // Otherwise plain text is still worth showing; timed lyrics of the wrong
        // cut would only be misleading.
        if let plain = candidates.compactMap({ $0["plainLyrics"] as? String }).first(where: { !$0.isEmpty }),
           let lyrics = Lyrics.parse(plain) {
            return (lyrics, candidates.contains { synced($0) != nil } ? "Only other cuts of this song have synced lyrics." : nil)
        }
        return (nil, candidates.contains { synced($0) != nil }
                ? "Only other cuts of this song have synced lyrics."
                : "LRCLIB has no lyrics for this song.")
    }

    // MARK: Re-checking saved lyrics

    /// Progress text for the menu: nil when idle.
    @Published private(set) var recheckStatus: String?

    /// Asks LRCLIB again for every song whose lyrics are saved and keeps the
    /// best-matching cut. Files saved by an older build carry no record of which
    /// song they are for, so they are removed and fetched afresh the next time
    /// that song plays.
    func recheckSaved() {
        guard recheckStatus == nil else { return }
        recheckStatus = "Checking saved lyrics…"
        Task { [weak self] in
            var checked = 0, changed = 0, dropped = 0
            let files = (try? FileManager.default.contentsOfDirectory(at: Self.cacheFolder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "lrc" {
                let old = try? String(contentsOf: file, encoding: .utf8)
                let metaLine = old?.split(separator: "\n").first { $0.hasPrefix("[zmp-meta:") }
                guard let metaLine,
                      let data = Data(base64Encoded: String(metaLine.dropFirst(10).dropLast())),
                      let query = try? JSONDecoder().decode(Query.self, from: data) else {
                    try? FileManager.default.removeItem(at: file)
                    dropped += 1
                    continue
                }
                try? FileManager.default.removeItem(at: file)
                let (lyrics, _) = await Self.fetchOnline(query)
                checked += 1
                let new = try? String(contentsOf: file, encoding: .utf8)
                // Compare the lyrics themselves, not the bookkeeping lines.
                func body(_ text: String?) -> String {
                    (text ?? "").split(separator: "\n").filter { !$0.hasPrefix("[zmp-") }.joined(separator: "\n")
                }
                if lyrics == nil || body(new) != body(old) { changed += 1 }
            }
            guard let self else { return }
            self.recheckStatus = "Checked \(checked) song\(checked == 1 ? "" : "s"), \(changed) updated"
                + (dropped > 0 ? ", \(dropped) older cleared" : "")
            // The song on screen may have a different cut now.
            if let track = self.currentTrack { self.load(track) }
            try? await Task.sleep(for: .seconds(8))
            self.recheckStatus = nil
        }
    }

    // MARK: Reading

    nonisolated static func find(for url: URL) async -> Lyrics? {
        if let sidecar = await Task.detached(priority: .utility, operation: { sidecar(for: url) }).value {
            return sidecar
        }
        if url.pathExtension.lowercased() == "flac" {
            let tags = await Task.detached(priority: .utility) { FLACTags.read(url) }.value
            for key in ["SYNCEDLYRICS", "LYRICS", "UNSYNCEDLYRICS", "LYRICS-ENG"] {
                if let text = tags?[key], let lyrics = Lyrics.parse(text) { return lyrics }
            }
            return nil
        }
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for id in [AVMetadataIdentifier.id3MetadataUnsynchronizedLyric, .iTunesMetadataLyrics] {
            if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
               let text = try? await item.load(.stringValue), let lyrics = Lyrics.parse(text) {
                return lyrics
            }
        }
        return nil
    }

    nonisolated static func sidecar(for url: URL) -> Lyrics? {
        let base = url.deletingPathExtension()
        for ext in ["lrc", "LRC", "txt", "TXT"] {
            let file = base.appendingPathExtension(ext)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size < 2 * 1024 * 1024,
                  let data = try? Data(contentsOf: file) else { continue }
            // Old LRC files are often not UTF-8.
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
                ?? String(decoding: data, as: UTF8.self)
            if let lyrics = Lyrics.parse(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text) { return lyrics }
        }
        return nil
    }
}
