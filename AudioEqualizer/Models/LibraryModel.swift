// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One audio file in the library, with the tags the browser groups by.
struct LibraryTrack: Identifiable, Codable, Equatable, Hashable {
    var url: URL
    var title: String
    var artist: String?
    var album: String?
    var genre: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var duration: Double?
    /// File size and modification time: a rescan re-reads tags only when one changes.
    var size: Int64
    var modified: Date

    var id: String { url.path }
    var artistName: String { artist ?? LibraryModel.unknownArtist }
    var albumName: String { album ?? LibraryModel.unknownAlbum }
}

/// A user's change to a song's tags. Kept beside the library rather than
/// written into the audio file, and re-applied after every rescan.
///
/// A nil field is untouched. For text, "" clears the tag; for numbers, 0 does.
struct TagEdit: Codable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?

    var isEmpty: Bool { self == TagEdit() }

    /// This edit with `newer` laid over it: its fields win where it sets them.
    func merged(with newer: TagEdit) -> TagEdit {
        TagEdit(title: newer.title ?? title, artist: newer.artist ?? artist,
                album: newer.album ?? album, genre: newer.genre ?? genre,
                year: newer.year ?? year, trackNumber: newer.trackNumber ?? trackNumber,
                discNumber: newer.discNumber ?? discNumber)
    }

    func apply(to track: LibraryTrack) -> LibraryTrack {
        func text(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        func number(_ value: Int) -> Int? { value > 0 ? value : nil }
        var t = track
        // A title cannot be empty: clearing it falls back to the file name.
        if let title { t.title = text(title) ?? LibraryModel.title(fromFilename: track.url) }
        if let artist { t.artist = text(artist) }
        if let album { t.album = text(album) }
        if let genre { t.genre = text(genre) }
        if let year { t.year = number(year) }
        if let trackNumber { t.trackNumber = number(trackNumber) }
        if let discNumber { t.discNumber = number(discNumber) }
        return t
    }
}

/// Pure grouping, sorting and tag-parsing for the library, kept free of UI and
/// audio frameworks so it can be tested on its own.
enum LibraryModel {
    static let unknownArtist = "Unknown Artist"
    static let unknownAlbum = "Unknown Album"

    /// Everything `AVAudioFile` decodes natively.
    static let audioExtensions: Set<String> = [
        "flac", "m4a", "alac", "wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "aac"
    ]

    struct Artist: Identifiable, Hashable {
        var name: String
        var trackCount: Int
        var id: String { name }
    }

    struct Album: Identifiable, Hashable {
        var artist: String
        var name: String
        var year: Int?
        var trackCount: Int
        var id: String { artist + "\u{1F}" + name }
    }

    /// Sort key: case and diacritic blind, and "The Beatles" files under B.
    static func sortKey(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) && folded.count > article.count {
            return String(folded.dropFirst(article.count))
        }
        return folded
    }

    private static func ordered(_ a: String, _ b: String) -> Bool {
        sortKey(a).localizedStandardCompare(sortKey(b)) == .orderedAscending
    }

    static func artists(_ tracks: [LibraryTrack]) -> [Artist] {
        Dictionary(grouping: tracks, by: \.artistName)
            .map { Artist(name: $0.key, trackCount: $0.value.count) }
            .sorted { ordered($0.name, $1.name) }
    }

    /// Albums by `artist`, or every album when it is nil. Oldest first within
    /// an artist, which is how a discography reads.
    static func albums(_ tracks: [LibraryTrack], artist: String?) -> [Album] {
        let pool = artist.map { name in tracks.filter { $0.artistName == name } } ?? tracks
        let groups = Dictionary(grouping: pool) { $0.artistName + "\u{1F}" + $0.albumName }
        return groups.values.map { group in
            Album(artist: group[0].artistName, name: group[0].albumName,
                  year: group.compactMap(\.year).min(), trackCount: group.count)
        }
        .sorted { a, b in
            if a.artist != b.artist { return ordered(a.artist, b.artist) }
            switch (a.year, b.year) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return ordered(a.name, b.name)
            }
        }
    }

    /// The songs under the current selection, filtered by `search`, in album
    /// order (disc, then track number, then title).
    static func songs(_ tracks: [LibraryTrack], artist: String?, album: Album?, search: String = "") -> [LibraryTrack] {
        var pool = tracks
        if let album {
            pool = pool.filter { $0.artistName == album.artist && $0.albumName == album.name }
        } else if let artist {
            pool = pool.filter { $0.artistName == artist }
        }
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            pool = pool.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || $0.artistName.localizedCaseInsensitiveContains(needle)
                    || $0.albumName.localizedCaseInsensitiveContains(needle)
                    || ($0.genre?.localizedCaseInsensitiveContains(needle) ?? false)
            }
        }
        return pool.sorted { a, b in
            if a.artistName != b.artistName { return ordered(a.artistName, b.artistName) }
            if a.albumName != b.albumName {
                if let ya = a.year, let yb = b.year, ya != yb { return ya < yb }
                return ordered(a.albumName, b.albumName)
            }
            if (a.discNumber ?? 1) != (b.discNumber ?? 1) { return (a.discNumber ?? 1) < (b.discNumber ?? 1) }
            switch (a.trackNumber, b.trackNumber) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    // MARK: Tag parsing

    /// "4", "04", "4/12" → 4. Anything else → nil.
    static func leadingNumber(_ text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        return Int(digits)
    }

    /// A year from "2009", "2009-01-01" or "(2009)".
    static func year(from text: String?) -> Int? {
        guard let text else { return nil }
        let scalars = Array(text)
        var i = 0
        while i + 4 <= scalars.count {
            let chunk = String(scalars[i..<i + 4])
            if let value = Int(chunk), (1900...2100).contains(value) { return value }
            i += 1
        }
        return nil
    }

    /// The track number a file name starts with: "04 - Title", "01. Title".
    /// Up to three digits, so a leading year ("1999 - Title") is not read as one.
    static func trackNumber(fromFilename name: String) -> Int? {
        let digits = name.prefix { $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        // A separator must follow ("04 - ", "01. ", "02_"): "7 Seconds" is a title.
        let rest = name.dropFirst(digits.count).drop { $0 == " " }
        guard let next = rest.first, "-._)".contains(next) else { return nil }
        return Int(digits)
    }

    /// A readable title from a file name: the extension and a leading
    /// track number ("04 - ", "01. ") removed.
    static func title(fromFilename url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if trackNumber(fromFilename: name) != nil {
            name = String(name.drop { $0.isNumber })
            name = String(name.drop { " -._".contains($0) })
        }
        return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }
}

/// Reads Vorbis comments out of a FLAC file. AVFoundation plays FLAC but
/// ignores its tags, so artist, album and track number have to come from here.
/// Only the comment block is read: lyrics and cover art can run to megabytes,
/// and the other blocks are skipped with a seek.
enum FLACTags {
    /// Upper-cased field names ("ARTIST") to values. nil when the file is not FLAC.
    static func read(_ url: URL) -> [String: String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }

        var fields: [String: String] = [:]
        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let isLast = header[header.startIndex] & 0x80 != 0
            let type = header[header.startIndex] & 0x7F
            let length = (Int(header[header.startIndex + 1]) << 16)
                | (Int(header[header.startIndex + 2]) << 8)
                | Int(header[header.startIndex + 3])

            if type == 4, length <= 8 * 1024 * 1024 {
                guard let block = try? handle.read(upToCount: length), block.count == length else { break }
                parseVorbisComment(block, into: &fields)
            } else if let position = try? handle.offset() {
                try? handle.seek(toOffset: position + UInt64(length))
            } else {
                break
            }
            if isLast { break }
        }
        return fields
    }

    static func parseVorbisComment(_ block: Data, into fields: inout [String: String]) {
        let bytes = [UInt8](block)
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            defer { i += 4 }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        guard let vendor = u32(), i + vendor <= bytes.count else { return }
        i += vendor
        guard let count = u32() else { return }
        for _ in 0..<count {
            guard let length = u32(), i + length <= bytes.count else { return }
            let entry = String(decoding: bytes[i..<i + length], as: UTF8.self)
            i += length
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<eq].uppercased()
            let value = String(entry[entry.index(after: eq)...])
            // The first value of a repeated field wins.
            if fields[key] == nil, !value.isEmpty { fields[key] = value }
        }
    }
}
