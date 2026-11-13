// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import AE2Core

/// Writes tags into real FLAC and MP3 files made with ffmpeg, then checks the
/// result with metaflac / ffprobe and that the audio itself is unchanged.
/// Skipped when those tools are not installed.
final class TagWriterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ae2-tagwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let candidates = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]
        guard let path = candidates.map({ $0 + args[0] }).first(where: FileManager.default.isExecutableFile) else {
            throw XCTSkip("\(args[0]) is not installed")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func make(_ name: String, extra: [String] = []) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-y"] + extra + [url.path])
        return url
    }

    /// MD5 of the decoded audio, independent of tags.
    private func audioHash(_ url: URL) throws -> String {
        try run(["ffmpeg", "-v", "error", "-i", url.path, "-map", "0:a", "-f", "md5", "-"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testFLACGrowsTagsKeepsAudioAndOtherFields() throws {
        let url = try make("a.flac", extra: ["-metadata", "ARTIST=Old", "-metadata", "DESCRIPTION=keep me"])
        let before = try audioHash(url)
        let long = String(repeating: "Long Album Name ", count: 800) // forces a full rewrite
        try TagWriter.write(TagEdit(album: long, genre: "Jazz", year: 2001, trackNumber: 7), to: url)

        let tags = try XCTUnwrap(FLACTags.read(url))
        XCTAssertEqual(tags["ARTIST"], "Old")
        XCTAssertEqual(tags["DESCRIPTION"], "keep me")
        XCTAssertEqual(tags["ALBUM"], long.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(tags["GENRE"], "Jazz")
        XCTAssertEqual(tags["DATE"], "2001")
        XCTAssertEqual(tags["TRACKNUMBER"], "7")
        XCTAssertEqual(try audioHash(url), before)
        XCTAssertTrue(try run(["flac", "-t", url.path]).contains("ok"))
    }

    func testFLACInPlaceEditAfterPaddingExists() throws {
        let url = try make("b.flac")
        try TagWriter.write(TagEdit(title: "First", artist: "A"), to: url) // gives the file padding
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        try TagWriter.write(TagEdit(title: "Second"), to: url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size)
        let tags = try XCTUnwrap(FLACTags.read(url))
        XCTAssertEqual(tags["TITLE"], "Second")
        XCTAssertEqual(tags["ARTIST"], "A")
        XCTAssertTrue(try run(["flac", "-t", url.path]).contains("ok"))
    }

    func testFLACClearsAFieldAndKeepsAlbumArtistInStep() throws {
        let url = try make("c.flac", extra: ["-metadata", "ARTIST=X", "-metadata", "ALBUMARTIST=X", "-metadata", "GENRE=Rock"])
        try TagWriter.write(TagEdit(artist: "Y", genre: ""), to: url)
        let tags = try XCTUnwrap(FLACTags.read(url))
        XCTAssertEqual(tags["ARTIST"], "Y")
        XCTAssertEqual(tags["ALBUMARTIST"], "Y")
        XCTAssertNil(tags["GENRE"])
    }

    func testMP3WithNoTagGetsOneAndStillDecodes() throws {
        let url = try make("d.mp3", extra: ["-id3v2_version", "0", "-write_id3v2", "0"])
        let before = try audioHash(url)
        try TagWriter.write(TagEdit(title: "Ünïcode Title", artist: "Band", album: "LP", genre: "Pop", year: 1999,
                                    trackNumber: 3, discNumber: 2), to: url)
        let probe = try run(["ffprobe", "-v", "error", "-show_entries", "format_tags", "-of", "default=nw=1", url.path])
        XCTAssertTrue(probe.contains("title=Ünïcode Title"), probe)
        XCTAssertTrue(probe.contains("artist=Band"), probe)
        XCTAssertTrue(probe.contains("album=LP"), probe)
        XCTAssertTrue(probe.contains("genre=Pop"), probe)
        XCTAssertTrue(probe.contains("track=3"), probe)
        XCTAssertTrue(probe.contains("disc=2"), probe)
        XCTAssertEqual(try audioHash(url), before)
    }

    func testMP3EditKeepsUntouchedFrames() throws {
        for version in ["3", "4"] {
            let url = try make("e\(version).mp3", extra: ["-id3v2_version", version, "-metadata", "artist=Keep", "-metadata", "title=Old"])
            try TagWriter.write(TagEdit(title: "New"), to: url)
            let probe = try run(["ffprobe", "-v", "error", "-show_entries", "format_tags", "-of", "default=nw=1", url.path])
            XCTAssertTrue(probe.contains("title=New"), "v2.\(version): \(probe)")
            XCTAssertTrue(probe.contains("artist=Keep"), "v2.\(version): \(probe)")
        }
    }

    func testUnsupportedTypeThrows() {
        XCTAssertThrowsError(try TagWriter.write(TagEdit(title: "x"), to: dir.appendingPathComponent("f.m4a")))
        XCTAssertFalse(TagWriter.canWrite(URL(fileURLWithPath: "/a.wav")))
    }
}
