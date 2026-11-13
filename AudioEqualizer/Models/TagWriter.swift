// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Writes tag edits into the audio files themselves: Vorbis comments for FLAC,
/// ID3v2 for MP3. Only the tag region is touched, the audio data is copied
/// byte for byte, and any tag field the edit does not name is left alone.
///
/// A tag that fits in the space the file already reserves is rewritten in
/// place. Otherwise the file is rewritten to a temporary file beside it and
/// swapped in atomically, so a failure part way leaves the original intact.
enum TagWriter {
    enum WriteError: Error, LocalizedError {
        case unsupported(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let why), .malformed(let why): return why
            }
        }
    }

    static let supportedExtensions: Set<String> = ["flac", "mp3"]

    static func canWrite(_ url: URL) -> Bool { supportedExtensions.contains(url.pathExtension.lowercased()) }

    static func write(_ edit: TagEdit, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "flac": try FLACWriter.write(edit, to: url)
        case "mp3": try ID3Writer.write(edit, to: url)
        default: throw WriteError.unsupported("Writing tags to .\(url.pathExtension) files is not supported")
        }
    }

    /// The edit's fields as plain strings; "" means remove the field.
    fileprivate static func fields(_ edit: TagEdit) -> [Field: String] {
        var out: [Field: String] = [:]
        func text(_ v: String?) -> String? { v?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let v = text(edit.title) { out[.title] = v }
        if let v = text(edit.artist) { out[.artist] = v }
        if let v = text(edit.album) { out[.album] = v }
        if let v = text(edit.genre) { out[.genre] = v }
        if let v = edit.year { out[.year] = v > 0 ? String(v) : "" }
        if let v = edit.trackNumber { out[.track] = v > 0 ? String(v) : "" }
        if let v = edit.discNumber { out[.disc] = v > 0 ? String(v) : "" }
        return out
    }

    fileprivate enum Field { case title, artist, album, genre, year, track, disc }

    /// Replaces `url` with the contents of `temp`.
    fileprivate static func swap(_ temp: URL, into url: URL) throws {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    fileprivate static func tempURL(beside url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".ae2-\(UUID().uuidString).tmp")
    }

    /// Copies `handle` from its current offset to the end into `out`.
    fileprivate static func copyRest(of handle: FileHandle, to out: FileHandle) throws {
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
    }
}

// MARK: - FLAC

private enum FLACWriter {
    struct Block { var type: UInt8; var data: Data }

    static func write(_ edit: TagEdit, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        // Some rips have an ID3v2 tag glued in front of the FLAC stream. That is
        // not valid FLAC: the tag is converted to Vorbis comments and dropped,
        // which means the file has to be rewritten rather than patched in place.
        let prefix = try ID3Prefix.read(from: handle)
        try handle.seek(toOffset: UInt64(prefix?.length ?? 0))
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else {
            throw TagWriter.WriteError.malformed("Not a FLAC file")
        }
        let base = prefix?.length ?? 0

        // Read every metadata block (they sit before the audio).
        var blocks: [Block] = []
        while true {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else {
                throw TagWriter.WriteError.malformed("Truncated FLAC header")
            }
            let isLast = header[header.startIndex] & 0x80 != 0
            let type = header[header.startIndex] & 0x7F
            let length = Int(header[header.startIndex + 1]) << 16 | Int(header[header.startIndex + 2]) << 8
                | Int(header[header.startIndex + 3])
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw TagWriter.WriteError.malformed("Truncated FLAC metadata")
            }
            blocks.append(Block(type: type, data: data))
            if isLast { break }
        }
        let audioStart = try handle.offset()
        let oldRegion = Int(audioStart) - 4 - base
        guard blocks.first?.type == 0 else { throw TagWriter.WriteError.malformed("FLAC has no STREAMINFO") }

        // Rebuild: edited comment block in place of the old one, padding dropped.
        var existing = blocks.first { $0.type == 4 }?.data
        if let prefix {
            // The ID3 values fill in what the FLAC's own comments lack.
            let own = existing.map(commentEntries) ?? []
            func key(_ entry: String) -> String? { entry.firstIndex(of: "=").map { entry[..<$0].uppercased() } }
            let have = Set(own.compactMap(key))
            let extra = prefix.entries.filter { key($0).map { !have.contains($0) } ?? false }
            existing = commentBlock(entries: own + extra)
        }
        let comment = updatedComment(existing, edit)
        var rebuilt: [Block] = []
        var placed = false
        for block in blocks where block.type != 1 {
            if block.type == 4 { rebuilt.append(Block(type: 4, data: comment)); placed = true }
            else { rebuilt.append(block) }
        }
        if !placed { rebuilt.insert(Block(type: 4, data: comment), at: 1) }

        let size = rebuilt.reduce(0) { $0 + 4 + $1.data.count }
        for b in rebuilt where b.data.count >= 1 << 24 { throw TagWriter.WriteError.malformed("Metadata block too large") }
        let spare = oldRegion - size

        if prefix == nil, spare == 0 || spare >= 4 {
            // Fits in the reserved space: rewrite just the metadata.
            var out = serialize(rebuilt, padding: spare == 0 ? nil : spare - 4)
            if out.count != oldRegion { out = serialize(rebuilt, padding: nil) }
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: out)
            try handle.synchronize()
            return
        }

        // Needs more room (or an unfillable 1-3 byte gap): rewrite the file.
        let temp = TagWriter.tempURL(beside: url)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw TagWriter.WriteError.malformed("Cannot create a temporary file next to the original")
        }
        do {
            let out = try FileHandle(forWritingTo: temp)
            defer { try? out.close() }
            try out.write(contentsOf: Data("fLaC".utf8))
            try out.write(contentsOf: serialize(rebuilt, padding: 8192))
            try handle.seek(toOffset: audioStart)
            try TagWriter.copyRest(of: handle, to: out)
            try out.synchronize()
            try TagWriter.swap(temp, into: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// The "NAME=value" entries of a Vorbis comment block.
    static func commentEntries(_ block: Data) -> [String] {
        let bytes = [UInt8](block)
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            defer { i += 4 }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        guard let vendor = u32(), i + vendor <= bytes.count else { return [] }
        i += vendor
        guard let count = u32() else { return [] }
        var out: [String] = []
        for _ in 0..<count {
            guard let len = u32(), i + len <= bytes.count else { break }
            out.append(String(decoding: bytes[i..<i + len], as: UTF8.self)); i += len
        }
        return out
    }

    /// A Vorbis comment block holding `entries` ("NAME=value").
    static func commentBlock(entries: [String]) -> Data {
        func le32(_ n: Int) -> Data { Data([UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)]) }
        let vendor = Data("Zuujis Media Player".utf8)
        var out = le32(vendor.count) + vendor + le32(entries.count)
        for entry in entries { let d = Data(entry.utf8); out += le32(d.count) + d }
        return out
    }

    /// Metadata blocks as bytes, followed by a padding block of `padding`
    /// bytes of payload when it is non-nil. The last block carries the flag.
    static func serialize(_ blocks: [Block], padding: Int?) -> Data {
        var all = blocks
        if let padding { all.append(Block(type: 1, data: Data(count: padding))) }
        var out = Data()
        for (i, block) in all.enumerated() {
            let n = block.data.count
            out.append(block.type | (i == all.count - 1 ? 0x80 : 0))
            out.append(contentsOf: [UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            out.append(block.data)
        }
        return out
    }

    private static let keys: [(TagWriter.Field, [String])] = [
        (.title, ["TITLE"]), (.artist, ["ARTIST"]), (.album, ["ALBUM"]), (.genre, ["GENRE"]),
        (.year, ["DATE", "YEAR"]), (.track, ["TRACKNUMBER", "TRACK"]), (.disc, ["DISCNUMBER", "DISC"]),
    ]

    /// The comment block with the edited fields replaced and everything else
    /// (vendor, unrelated fields, repeated fields) kept as it was.
    static func updatedComment(_ old: Data?, _ edit: TagEdit) -> Data {
        var vendor = Data("Zuujis Media Player".utf8)
        var entries: [String] = []
        if let old {
            let bytes = [UInt8](old)
            var i = 0
            func u32() -> Int? {
                guard i + 4 <= bytes.count else { return nil }
                defer { i += 4 }
                return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
            }
            if let n = u32(), i + n <= bytes.count {
                vendor = Data(bytes[i..<i + n]); i += n
                if let count = u32() {
                    for _ in 0..<count {
                        guard let len = u32(), i + len <= bytes.count else { break }
                        entries.append(String(decoding: bytes[i..<i + len], as: UTF8.self)); i += len
                    }
                }
            }
        }

        let changes = TagWriter.fields(edit)
        func name(_ entry: String) -> String? { entry.firstIndex(of: "=").map { entry[..<$0].uppercased() } }
        var drop = Set<String>()
        for (field, names) in keys where changes[field] != nil { drop.formUnion(names) }
        // The library shows the album artist first, so keep it in step.
        let hadAlbumArtist = entries.contains { ["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"].contains(name($0) ?? "") }
        if changes[.artist] != nil, hadAlbumArtist { drop.formUnion(["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"]) }
        entries.removeAll { drop.contains(name($0) ?? "") }
        for (field, names) in keys {
            if let value = changes[field], !value.isEmpty { entries.append("\(names[0])=\(value)") }
        }
        if changes[.artist] != nil, hadAlbumArtist, let v = changes[.artist], !v.isEmpty {
            entries.append("ALBUMARTIST=\(v)")
        }

        var out = Data()
        func put(_ n: Int) { out.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)]) }
        put(vendor.count); out.append(vendor)
        put(entries.count)
        for e in entries { let d = Data(e.utf8); put(d.count); out.append(d) }
        return out
    }
}

// MARK: - ID3v2

private enum ID3Writer {
    struct Frame { var id: String; var flags: [UInt8]; var body: Data }

    static func write(_ edit: TagEdit, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        var version: UInt8 = 4
        var frames: [Frame] = []
        var oldTotal = 0 // bytes taken by an existing tag, header included

        if let head = try handle.read(upToCount: 10), head.count == 10, head.prefix(3) == Data("ID3".utf8) {
            let b = [UInt8](head)
            version = b[3]
            guard version == 3 || version == 4 else {
                throw TagWriter.WriteError.unsupported("ID3v2.\(version) tags are not supported")
            }
            guard b[5] & 0x80 == 0 else { throw TagWriter.WriteError.unsupported("Unsynchronised ID3 tags are not supported") }
            let size = syncsafe(b[6...9])
            guard let body = try handle.read(upToCount: size), body.count == size else {
                throw TagWriter.WriteError.malformed("Truncated ID3 tag")
            }
            oldTotal = 10 + size
            var bytes = [UInt8](body)
            if b[5] & 0x40 != 0, bytes.count >= 4 { // extended header: dropped on rewrite
                let ext = version == 4 ? syncsafe(bytes[0...3]) : 4 + Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
                bytes = Array(bytes.dropFirst(min(ext, bytes.count)))
            }
            var i = 0
            while i + 10 <= bytes.count, bytes[i] != 0 {
                let id = String(decoding: bytes[i..<i + 4], as: UTF8.self)
                let n = version == 4 ? syncsafe(bytes[i + 4...i + 7])
                    : Int(bytes[i + 4]) << 24 | Int(bytes[i + 5]) << 16 | Int(bytes[i + 6]) << 8 | Int(bytes[i + 7])
                guard i + 10 + n <= bytes.count else { break }
                frames.append(Frame(id: id, flags: [bytes[i + 8], bytes[i + 9]], body: Data(bytes[i + 10..<i + 10 + n])))
                i += 10 + n
            }
        }

        let changes = TagWriter.fields(edit)
        func replace(_ ids: [String], with value: String?, as id: String) {
            frames.removeAll { ids.contains($0.id) }
            if let value, !value.isEmpty { frames.append(Frame(id: id, flags: [0, 0], body: textBody(value))) }
        }
        if let v = changes[.title] { replace(["TIT2"], with: v, as: "TIT2") }
        if let v = changes[.artist] {
            replace(["TPE1"], with: v, as: "TPE1")
            if frames.contains(where: { $0.id == "TPE2" }) { replace(["TPE2"], with: v, as: "TPE2") }
        }
        if let v = changes[.album] { replace(["TALB"], with: v, as: "TALB") }
        if let v = changes[.genre] { replace(["TCON"], with: v, as: "TCON") }
        if let v = changes[.year] { replace(["TYER", "TDRC"], with: v, as: version == 4 ? "TDRC" : "TYER") }
        if let v = changes[.track] { replace(["TRCK"], with: v, as: "TRCK") }
        if let v = changes[.disc] { replace(["TPOS"], with: v, as: "TPOS") }

        var payload = Data()
        for f in frames {
            payload.append(Data(f.id.utf8))
            let n = f.body.count
            if version == 4 { payload.append(contentsOf: syncsafeBytes(n)) }
            else { payload.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) }
            payload.append(contentsOf: f.flags)
            payload.append(f.body)
        }

        func header(_ size: Int) -> Data {
            Data([0x49, 0x44, 0x33, version, 0, 0] + syncsafeBytes(size))
        }

        if oldTotal > 0, 10 + payload.count <= oldTotal {
            // Fits in the old tag's space: pad the rest with zeros.
            var out = header(oldTotal - 10)
            out.append(payload)
            out.append(Data(count: oldTotal - out.count))
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: out)
            try handle.synchronize()
            return
        }

        let padding = 2048
        var tag = header(payload.count + padding)
        tag.append(payload)
        tag.append(Data(count: padding))

        let temp = TagWriter.tempURL(beside: url)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw TagWriter.WriteError.malformed("Cannot create a temporary file next to the original")
        }
        do {
            let out = try FileHandle(forWritingTo: temp)
            defer { try? out.close() }
            try out.write(contentsOf: tag)
            try handle.seek(toOffset: UInt64(oldTotal))
            try TagWriter.copyRest(of: handle, to: out)
            try out.synchronize()
            try TagWriter.swap(temp, into: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// UTF-16 with a byte-order mark: valid in both v2.3 and v2.4, and v2.3
    /// has no UTF-8.
    private static func textBody(_ text: String) -> Data {
        var d = Data([1, 0xFF, 0xFE])
        d.append(text.data(using: .utf16LittleEndian) ?? Data())
        return d
    }

    private static func syncsafe<S: Sequence>(_ bytes: S) -> Int where S.Element == UInt8 {
        bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    private static func syncsafeBytes(_ n: Int) -> [UInt8] {
        [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)]
    }
}


// MARK: - ID3 in front of FLAC

/// An ID3v2 tag at the start of a file, read only so its text frames can be
/// carried over as Vorbis comments. Handles v2.3 and v2.4, with or without
/// unsynchronisation.
enum ID3Prefix {
    struct Tag { var length: Int; var entries: [String] }

    /// The tag at the start of `handle`, or nil when the file does not begin with one.
    static func read(from handle: FileHandle) throws -> Tag? {
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: 10), head.count == 10,
              head.prefix(3) == Data("ID3".utf8) else { return nil }
        let bytes = [UInt8](head)
        let version = Int(bytes[3]), flags = bytes[5]
        let size = Int(bytes[6] & 0x7F) << 21 | Int(bytes[7] & 0x7F) << 14 | Int(bytes[8] & 0x7F) << 7 | Int(bytes[9] & 0x7F)
        let length = 10 + size + (flags & 0x10 != 0 ? 10 : 0)
        guard version == 3 || version == 4, let body = try handle.read(upToCount: size), body.count == size else {
            return Tag(length: length, entries: [])
        }
        var data = [UInt8](body)
        if flags & 0x80 != 0 {
            var plain: [UInt8] = []
            var i = 0
            while i < data.count {
                plain.append(data[i])
                if data[i] == 0xFF, i + 1 < data.count, data[i + 1] == 0 { i += 1 }
                i += 1
            }
            data = plain
        }
        var i = 0
        if flags & 0x40 != 0, data.count >= 4 {   // extended header
            let n = version == 4
                ? Int(data[0] & 0x7F) << 21 | Int(data[1] & 0x7F) << 14 | Int(data[2] & 0x7F) << 7 | Int(data[3] & 0x7F)
                : 4 + (Int(data[0]) << 24 | Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3]))
            i = min(n, data.count)
        }
        let names = ["TIT2": "TITLE", "TPE1": "ARTIST", "TALB": "ALBUM", "TCON": "GENRE", "TRCK": "TRACKNUMBER",
                     "TPOS": "DISCNUMBER", "TYER": "DATE", "TDRC": "DATE", "TPE2": "ALBUMARTIST", "TCOM": "COMPOSER"]
        var entries: [String] = []
        var seen = Set<String>()
        while i + 10 <= data.count, data[i] != 0 {
            let id = String(decoding: data[i..<i + 4], as: UTF8.self)
            let n = version == 4
                ? Int(data[i + 4] & 0x7F) << 21 | Int(data[i + 5] & 0x7F) << 14 | Int(data[i + 6] & 0x7F) << 7 | Int(data[i + 7] & 0x7F)
                : Int(data[i + 4]) << 24 | Int(data[i + 5]) << 16 | Int(data[i + 6]) << 8 | Int(data[i + 7])
            i += 10
            guard n >= 0, i + n <= data.count else { break }
            if let name = names[id], n > 1, !seen.contains(name), let text = decode(Array(data[i..<i + n])), !text.isEmpty {
                // A bare "(17)" genre is an index into the old ID3v1 list, not a name.
                if !(name == "GENRE" && text.hasPrefix("(") && text.hasSuffix(")")) {
                    entries.append("\(name)=\(text)")
                    seen.insert(name)
                }
            }
            i += n
        }
        return Tag(length: length, entries: entries)
    }

    private static func decode(_ frame: [UInt8]) -> String? {
        guard let encoding = frame.first else { return nil }
        let body = Array(frame.dropFirst())
        let string: String?
        switch encoding {
        case 0: string = String(bytes: body, encoding: .isoLatin1)
        case 1: string = String(bytes: body, encoding: .utf16)
        case 2: string = String(bytes: body, encoding: .utf16BigEndian)
        default: string = String(bytes: body, encoding: .utf8)
        }
        return string?.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
