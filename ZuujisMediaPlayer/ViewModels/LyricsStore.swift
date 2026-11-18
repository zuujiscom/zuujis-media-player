// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
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
/// With the lookup on, a song whose own lyrics are untimed is also looked up,
/// and LRCLIB's synced lyrics replace them when it has some.
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
            if onlineLookup, lyrics?.isSynced != true, !isLoading, let track = currentTrack { load(track) }
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
        // A timed .lrc saved beside the playing song after its lyrics loaded
        // (made by hand or another tool) is picked up on returning to the app.
        activation = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.recheckSidecar() }
    }

    private var activation: AnyCancellable?

    // MARK: Timing untimed lyrics

    /// Progress or the last failure of "Time These Lyrics"; nil when idle.
    @Published private(set) var timingStatus: String?
    @Published private(set) var isTiming = false

    /// Listens to the playing song with on-device speech recognition and
    /// times its lyrics word by word (line by line too when they were
    /// untimed), saved in the app's folder (see `LyricsTimer`).
    func timeCurrentLyrics() {
        guard let track = currentTrack, let plain = lyrics, !plain.hasWordTimes, !isTiming, batchStatus == nil else { return }
        isTiming = true
        timingStatus = "Starting…"
        Task { [weak self] in
            do {
                let timed = try await LyricsTimer.time(plain, song: track.url, title: track.title, artist: track.artist) { text in
                    if self?.url == track.url { self?.timingStatus = text }
                }
                guard let self else { return }
                self.isTiming = false
                self.timingStatus = nil
                if self.url == track.url { self.lyrics = timed; self.onlineMessage = nil }
            } catch {
                guard let self else { return }
                self.isTiming = false
                self.timingStatus = error.localizedDescription
                try? await Task.sleep(for: .seconds(8))
                if !self.isTiming { self.timingStatus = nil }
            }
        }
    }

    /// Swaps in better lyrics if they have appeared since the song loaded (a
    /// word-timed copy, or a timed .lrc beside the song while the shown ones
    /// are untimed); quiet otherwise (no reload, no flicker).
    func recheckSidecar() {
        guard let url, lyrics?.hasWordTimes != true, !isLoading else { return }
        let shownSynced = lyrics?.isSynced == true
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                Self.wordTimed(for: url) ?? (shownSynced ? nil : Self.sidecar(for: url))
            }.value
            guard let self, self.url == url, let found, found.isSynced || self.lyrics == nil else { return }
            self.lyrics = found
            self.onlineMessage = nil
        }
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
            // Plain lyrics in the file are kept unless LRCLIB has timed ones,
            // since many rips embed the words without timing.
            let local = found
            if found?.isSynced != true, online {
                // The player's copy of the tags may still be loading.
                var asked = Query(track)
                let meta = await TrackMetadata.read(track.url)
                if let title = meta.title, !title.isEmpty { asked.title = title }
                asked.artist = meta.artist ?? track.artist
                asked.album = meta.album ?? track.album
                asked.title = Self.withoutArtist(asked.title, artist: asked.artist)
                let (fetched, why) = await Self.fetchOnline(asked)
                if let local, fetched?.isSynced != true {
                    found = local          // nothing better online
                } else {
                    (found, message) = (fetched, why)
                }
            }
            guard !Task.isCancelled, let self, self.url == track.url else { return }
            // The title and artist can still be filling in from the tags; a
            // miss is remembered only for this run.
            if found?.isSynced != true, online { self.missed.insert(track.url) }
            self.lyrics = found
            self.onlineMessage = message
            self.isLoading = false
        }
    }

    /// Some rips put the artist into the title ("Broken Wings - Bryan Adams" or
    /// "Bryan Adams - Broken Wings"), which LRCLIB never matches.
    nonisolated static func withoutArtist(_ title: String, artist: String?) -> String {
        guard let artist, !artist.isEmpty else { return title }
        for (sep) in [" - ", " – ", " — "] {
            if title.lowercased().hasSuffix((sep + artist).lowercased()) {
                return String(title.dropLast(sep.count + artist.count))
            }
            if title.lowercased().hasPrefix((artist + sep).lowercased()) {
                return String(title.dropFirst(artist.count + sep.count))
            }
        }
        return title
    }

    // MARK: Timing words for many songs

    /// Progress of a batch ("Timing words: 12 of 140 — Song"); nil when idle.
    @Published private(set) var batchStatus: String?
    private var batchTask: Task<Void, Never>?

    /// Times the words of every given song that has lyrics without word times,
    /// one after another. Songs already done are skipped, so stopping and
    /// starting again carries on where it left off.
    func timeWords(for songs: [LibraryTrack], label: String) {
        guard batchTask == nil, !isTiming else { return }
        let useOnline = onlineLookup
        batchStatus = "Timing words: starting…"
        batchTask = Task { [weak self] in
            var done = 0, skipped = 0, failed = 0
            for (index, song) in songs.enumerated() {
                if Task.isCancelled { break }
                if LyricsTimer.currentWordsText(for: song.url) != nil { skipped += 1; continue }
                var lyrics = await Self.find(for: song.url)
                if lyrics?.isSynced != true, useOnline, let artist = song.artist, !artist.isEmpty {
                    let asked = Query(path: song.url.path, title: Self.withoutArtist(song.title, artist: artist),
                                      artist: artist, album: song.album, duration: song.duration ?? 0)
                    if let online = await Self.fetchOnline(asked).0, online.isSynced || lyrics == nil { lyrics = online }
                }
                guard let lyrics, !lyrics.hasWordTimes else { skipped += 1; continue }
                await MainActor.run {
                    self?.batchStatus = "Timing words: \(index + 1) of \(songs.count) — \(song.title)"
                }
                do {
                    let timed = try await LyricsTimer.time(lyrics, song: song.url, title: song.title, artist: song.artist) { _ in }
                    done += 1
                    await MainActor.run {
                        if let self, self.url == song.url { self.lyrics = timed }
                    }
                } catch {
                    if Task.isCancelled { break }
                    failed += 1
                }
            }
            await MainActor.run {
                guard let self else { return }
                let stopped = Task.isCancelled ? "Stopped. " : ""
                self.batchStatus = "\(stopped)\(label): \(done) timed, \(skipped) skipped" + (failed > 0 ? ", \(failed) failed" : "")
                self.batchTask = nil
            }
            try? await Task.sleep(for: .seconds(12))
            await MainActor.run { if self?.batchTask == nil { self?.batchStatus = nil } }
        }
    }

    func stopTimingWords() { batchTask?.cancel() }
    var isTimingBatch: Bool { batchTask != nil }

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

        init(path: String, title: String, artist: String?, album: String?, duration: Double) {
            self.path = path; self.title = title; self.artist = artist; self.album = album; self.duration = duration
        }
    }

    /// A song comes in several cuts (radio edit, album, extended) and LRCLIB
    /// keeps each one's own timing, so a synced version is only used when its
    /// length is close to the file's.
    /// Simpler forms of a tagged title, most specific first: guest credits
    /// and "(Skit)"-style notes removed, a leading "Guest - " dropped, and
    /// censored words ("N****z") turned into a wildcard-free form.
    nonisolated static func titleVariants(_ title: String) -> [String] {
        var out: [String] = []
        func add(_ t: String) {
            let t = t.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
        }
        let credit = #"\s*[\(\[]\s*(feat\.?|featuring|ft\.?|with|prod\.?)\s[^\)\]]*[\)\]]"#
        let anyBracket = #"\s*[\(\[][^\)\]]*[\)\]]"#
        let trailingFeat = #"\s+(feat\.?|featuring|ft\.?)\s.*$"#
        func re(_ s: String, _ pattern: String) -> String {
            s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        var bases = [title]
        // "Project Pat - Drive By": the part after the dash is the song.
        for sep in [" - ", " – ", " — "] where title.contains(sep) {
            bases.append(String(title[title.range(of: sep)!.upperBound...]))
        }
        for b in bases {
            let noCredit = re(re(b, credit), trailingFeat)
            add(noCredit)
            add(re(noCredit, anyBracket))
            add(noCredit.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")"))
        }
        // Censored words: LRCLIB's titles are usually spelled out.
        for t in out where t.contains("*") {
            add(t.replacingOccurrences(of: #"\w*\*+\w*"#, with: "", options: .regularExpression))
        }
        // "Part Ii" from title-casing.
        for t in out where t.range(of: #"\bIi\b"#, options: .regularExpression) != nil {
            add(t.replacingOccurrences(of: #"\bIi\b"#, with: "II", options: .regularExpression))
        }
        return out
    }

    /// Loose comparison key: letters and digits only, credits and brackets removed.
    nonisolated static func titleKey(_ title: String) -> String {
        (titleVariants(title).last(where: { !$0.contains("(") && !$0.contains("[") }) ?? title)
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Plain lyrics from lyrics.ovh (free, no key): the second source, used
    /// only when LRCLIB has no lyrics at all. Tries the cleaned titles too.
    nonisolated static func lyricsOVH(title: String, artist: String) async -> String? {
        for name in ([title] + titleVariants(title).filter { $0 != title }).prefix(4) {
            let path = "https://api.lyrics.ovh/v1/"
                + (artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? "") + "/"
                + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? "")
            guard let url = URL(string: path) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("ZuujisMediaPlayer (https://github.com/zuujiscom/zuujis-media-player)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var text = json["lyrics"] as? String else { continue }
            // Its first line is often "Paroles de la chanson … par …".
            if text.hasPrefix("Paroles de la chanson"), let cut = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: cut)...])
            }
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    // MARK: Pasted lyrics

    /// Lyrics the user pasted for a song, kept in the app's folder (never
    /// beside the music) under a name made from the song's path.
    nonisolated static func pastedFile(for url: URL) -> URL {
        let dir = AppPaths.support.appendingPathComponent("Lyrics/Pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var hash: UInt64 = 5381
        for byte in url.path.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return dir.appendingPathComponent(String(hash, radix: 16) + ".txt")
    }

    nonisolated static func pasted(for url: URL) -> Lyrics? {
        guard let text = try? String(contentsOf: pastedFile(for: url), encoding: .utf8) else { return nil }
        return Lyrics.parse(text)
    }

    /// Saves the clipboard's text as this song's lyrics and shows them.
    /// Returns false when the clipboard holds no usable text.
    @discardableResult
    func pasteLyrics(_ text: String, for url: URL) -> Bool {
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, Lyrics.parse(cleaned) != nil else { return false }
        do { try cleaned.write(to: Self.pastedFile(for: url), atomically: true, encoding: .utf8) } catch { return false }
        // A timed copy made from earlier lyrics would hide the new ones.
        try? FileManager.default.removeItem(at: LyricsTimer.wordsFile(for: url))
        missed.remove(url)
        if let track = currentTrack, track.url == url { load(track) }
        return true
    }

    /// Forgets pasted lyrics for this song.
    func removePastedLyrics(for url: URL) {
        try? FileManager.default.removeItem(at: Self.pastedFile(for: url))
        // The timed copy was made from the pasted text, so it goes too.
        try? FileManager.default.removeItem(at: LyricsTimer.wordsFile(for: url))
        if let track = currentTrack, track.url == url { load(track) }
    }

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
        // Titles with extra words ("(feat. …)", "(Skit)", "Guest - Song",
        // censored words) often miss: try cleaned titles, then a free-text
        // search, keeping only results whose title matches.
        func hasSynced(_ list: [[String: Any]]) -> Bool {
            list.contains { ($0["syncedLyrics"] as? String).map { !$0.isEmpty } ?? false }
        }
        if !hasSynced(candidates) {
            let variants = titleVariants(track.title).filter { $0 != track.title }
            for title in variants {
                if let found = await request("search", [
                    URLQueryItem(name: "track_name", value: title),
                    URLQueryItem(name: "artist_name", value: artist),
                ]) as? [[String: Any]] { candidates += found }
                if hasSynced(candidates) { break }
            }
            if !hasSynced(candidates) {
                let keys = Set(([track.title] + variants).map(titleKey))
                for title in [track.title] + variants.prefix(2) {
                    if let found = await request("search", [URLQueryItem(name: "q", value: "\(title) \(artist)")]) as? [[String: Any]] {
                        candidates += found.filter { keys.contains(titleKey(($0["trackName"] as? String) ?? "")) }
                    }
                    if let found = await request("search", [URLQueryItem(name: "track_name", value: title)]) as? [[String: Any]] {
                        candidates += found.filter { keys.contains(titleKey(($0["trackName"] as? String) ?? "")) }
                    }
                    if hasSynced(candidates) { break }
                }
            }
        }
        if candidates.isEmpty {
            if let text = await lyricsOVH(title: track.title, artist: artist), let lyrics = Lyrics.parse(text) {
                return (lyrics, nil)
            }
            return (nil, "Not found on LRCLIB or lyrics.ovh.")
        }

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
        // cut would only be misleading. lyrics.ovh fills in when LRCLIB has none.
        let lrclibPlain = candidates.contains { ($0["plainLyrics"] as? String).map { !$0.isEmpty } ?? false }
        if !lrclibPlain, let text = await lyricsOVH(title: track.title, artist: artist), let lyrics = Lyrics.parse(text) {
            return (lyrics, nil)
        }
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
                _ = await Self.fetchOnline(query)
                checked += 1
                var new = try? String(contentsOf: file, encoding: .utf8)
                // Nothing came back (offline, LRCLIB down, or it no longer has
                // the song): keep what was saved rather than lose it.
                if new == nil, let old {
                    try? old.write(to: file, atomically: true, encoding: .utf8)
                    new = old
                }
                // Compare the lyrics themselves, not the bookkeeping lines.
                func body(_ text: String?) -> String {
                    (text ?? "").split(separator: "\n").filter { !$0.hasPrefix("[zmp-") }.joined(separator: "\n")
                }
                if body(new) != body(old) { changed += 1 }
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
        if let words = await Task.detached(priority: .utility, operation: { wordTimed(for: url) }).value {
            return words
        }
        if let pasted = await Task.detached(priority: .utility, operation: { pasted(for: url) }).value {
            return pasted
        }
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

    /// The app's own word-timed copy ("Time These Lyrics"), if one was made.
    nonisolated static func wordTimed(for url: URL) -> Lyrics? {
        guard let text = LyricsTimer.currentWordsText(for: url),
              let lyrics = Lyrics.parse(text), lyrics.isSynced else { return nil }
        return lyrics
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
