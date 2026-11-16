// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads the ReplayGain values out of a file's tags, plus the album it says it
/// belongs to. Only the tag area is read, never the audio, so this is quick
/// enough to do as a song starts.
///
/// - FLAC: Vorbis comments (`REPLAYGAIN_TRACK_GAIN` …).
/// - MP3: ID3v2 `TXXX` frames with those names, in any case.
/// - M4A: iTunes freeform atoms (`----:com.apple.iTunes:replaygain_track_gain`).
///
/// Not read: APEv2 tags and the LAME header on MP3, and anything on WAV/AIFF.
/// Those files are measured instead.
enum ReplayGainTags {
    struct Result: Equatable, Sendable {
        var info = ReplayGainInfo()
        /// "artist␟album" (album artist preferred), nil when the file names no album.
        var album: String?
    }

    static func read(_ url: URL) -> Result {
        var fields: [String: String] = [:]
        switch url.pathExtension.lowercased() {
        case "flac":
            fields = FLACTags.read(url) ?? [:]
        case "mp3":
            guard let handle = try? FileHandle(forReadingFrom: url) else { break }
            defer { try? handle.close() }
            for entry in ((try? ID3Prefix.read(from: handle)) ?? nil)?.entries ?? [] {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<eq]).uppercased()
                if fields[key] == nil { fields[key] = String(entry[entry.index(after: eq)...]) }
            }
        case "m4a", "alac", "mp4", "m4b":
            fields = MP4Tags.read(url)
        default:
            break
        }
        return Result(info: ReplayGainInfo(tags: fields), album: albumKey(fields))
    }

    static func albumKey(artist: String?, album: String?) -> String? {
        guard let album = album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty else { return nil }
        return (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\u{1F}" + album.lowercased()
    }

    private static func albumKey(_ fields: [String: String]) -> String? {
        albumKey(artist: fields["ALBUMARTIST"] ?? fields["ALBUM ARTIST"] ?? fields["ALBUM_ARTIST"] ?? fields["ARTIST"],
                 album: fields["ALBUM"])
    }
}

/// The few iTunes-style tags this app needs from an MPEG-4 file, read by
/// walking the atoms: `moov › udta › meta › ilst`.
enum MP4Tags {
    /// Upper-cased names to values: `ALBUM`, `ARTIST`, `ALBUMARTIST` and any
    /// freeform (`----`) item, e.g. `REPLAYGAIN_TRACK_GAIN`.
    static func read(_ url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [:] }

        // Top level: find `moov`, which may sit before or after the audio.
        var offset: UInt64 = 0
        while offset + 8 <= end {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let head = try? handle.read(upToCount: 16), head.count >= 8 else { return [:] }
            let b = [UInt8](head)
            var size = UInt64(be32(b, 0))
            var headerSize: UInt64 = 8
            if size == 1, b.count >= 16 {
                size = (UInt64(be32(b, 8)) << 32) | UInt64(be32(b, 12))
                headerSize = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= headerSize, offset + size <= end else { return [:] }
            if b[4...7].elementsEqual("moov".utf8) {
                let length = size - headerSize
                guard length <= 64 * 1024 * 1024,
                      (try? handle.seek(toOffset: offset + headerSize)) != nil,
                      let body = try? handle.read(upToCount: Int(length)), body.count == Int(length) else { return [:] }
                return parse(moov: [UInt8](body))
            }
            offset += size
        }
        return [:]
    }

    static func parse(moov b: [UInt8]) -> [String: String] {
        guard let udta = child("udta", b, 0, b.count), let meta = child("meta", b, udta.start, udta.end) else { return [:] }
        // iTunes' `meta` starts with four bytes of version and flags; QuickTime's does not.
        guard let ilst = child("ilst", b, meta.start + 4, meta.end) ?? child("ilst", b, meta.start, meta.end) else { return [:] }

        var fields: [String: String] = [:]
        let named: [[UInt8]: String] = [
            [0xA9] + Array("alb".utf8): "ALBUM",
            [0xA9] + Array("ART".utf8): "ARTIST",
            Array("aART".utf8): "ALBUMARTIST",
        ]
        for item in atoms(b, ilst.start, ilst.end) {
            let parts = atoms(b, item.start, item.end)
            guard let data = parts.first(where: { $0.type == Array("data".utf8) }),
                  data.end - data.start >= 8 else { continue }
            let value = String(decoding: b[(data.start + 8)..<data.end], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if item.type == Array("----".utf8) {
                guard let name = parts.first(where: { $0.type == Array("name".utf8) }),
                      name.end - name.start > 4 else { continue }
                let key = String(decoding: b[(name.start + 4)..<name.end], as: UTF8.self).uppercased()
                if fields[key] == nil { fields[key] = value }
            } else if let key = named[item.type], fields[key] == nil {
                fields[key] = value
            }
        }
        return fields
    }

    private struct Atom { var type: [UInt8]; var start: Int; var end: Int }

    /// The atoms laid end to end in `b[from..<to]`, with their payload ranges.
    private static func atoms(_ b: [UInt8], _ from: Int, _ to: Int) -> [Atom] {
        var out: [Atom] = []
        var i = from
        while i >= 0, i + 8 <= to, to <= b.count {
            var size = be32(b, i)
            if size == 0 { size = to - i }
            guard size >= 8, i + size <= to else { break }
            out.append(Atom(type: Array(b[(i + 4)..<(i + 8)]), start: i + 8, end: i + size))
            i += size
        }
        return out
    }

    private static func child(_ type: String, _ b: [UInt8], _ from: Int, _ to: Int) -> Atom? {
        atoms(b, from, to).first { $0.type == Array(type.utf8) }
    }

    private static func be32(_ b: [UInt8], _ at: Int) -> Int {
        guard at >= 0, at + 4 <= b.count else { return 0 }
        return Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
    }
}
