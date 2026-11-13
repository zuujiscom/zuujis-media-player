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
                var asked = track
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

    private nonisolated static func cacheFile(for url: URL) -> URL {
        // A stable name from the path; the file's contents are the lyrics.
        var hash: UInt64 = 5381
        for byte in url.path.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return cacheFolder.appendingPathComponent(String(hash, radix: 16) + ".lrc")
    }

    /// Asks lrclib.net for the song, preferring synced lyrics. Returns the
    /// lyrics, or nil and a short reason.
    nonisolated static func fetchOnline(_ track: PlayerEngine.TrackInfo) async -> (Lyrics?, String?) {
        let cache = cacheFile(for: track.url)
        if let cached = try? String(contentsOf: cache, encoding: .utf8), let lyrics = Lyrics.parse(cached) {
            return (lyrics, nil)
        }
        guard let artist = track.artist, !artist.isEmpty, !track.title.isEmpty else {
            return (nil, "Needs a title and artist in the tags.")
        }
        var parts = URLComponents(string: "https://lrclib.net/api/get")!
        parts.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: track.album ?? ""),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        guard let request = parts.url else { return (nil, nil) }
        var req = URLRequest(url: request, timeoutInterval: 10)
        req.setValue("ZuujisMediaPlayer (https://github.com/zuujiscom/zuujis-media-player)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { return (nil, "Not found on LRCLIB.") }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, "LRCLIB did not answer.")
            }
            let text = (json["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (json["plainLyrics"] as? String) ?? ""
            guard let lyrics = Lyrics.parse(text) else { return (nil, "LRCLIB has no lyrics for this song.") }
            try? text.write(to: cache, atomically: true, encoding: .utf8)
            return (lyrics, nil)
        } catch {
            return (nil, "Could not reach LRCLIB.")
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
