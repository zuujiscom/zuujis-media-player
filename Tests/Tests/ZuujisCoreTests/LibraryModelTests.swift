import XCTest
@testable import ZuujisCore

final class LibraryModelTests: XCTestCase {
    private func track(_ title: String, artist: String?, album: String?, no: Int? = nil,
                       disc: Int? = nil, year: Int? = nil) -> LibraryTrack {
        LibraryTrack(url: URL(fileURLWithPath: "/m/\(artist ?? "x")/\(album ?? "y")/\(title).flac"),
                     title: title, artist: artist, album: album, trackNumber: no, discNumber: disc,
                     year: year, duration: 200, size: 1, modified: Date(timeIntervalSince1970: 0))
    }

    private var library: [LibraryTrack] {
        [
            track("One", artist: "The Beatles", album: "Abbey Road", no: 1, year: 1969),
            track("Two", artist: "The Beatles", album: "Abbey Road", no: 2, year: 1969),
            track("Help", artist: "The Beatles", album: "Help!", no: 1, year: 1965),
            track("Zed", artist: "Abba", album: "Arrival", no: 1, year: 1976),
            track("Loose", artist: nil, album: nil),
        ]
    }

    func testArtistsIgnoreLeadingArticleAndKeepUnknown() {
        let names = LibraryModel.artists(library).map(\.name)
        XCTAssertEqual(names, ["Abba", "The Beatles", "Unknown Artist"])
        XCTAssertEqual(LibraryModel.artists(library).first { $0.name == "The Beatles" }?.trackCount, 3)
    }

    func testAlbumsAreOldestFirstWithinAnArtist() {
        let albums = LibraryModel.albums(library, artist: "The Beatles")
        XCTAssertEqual(albums.map(\.name), ["Help!", "Abbey Road"])
        XCTAssertEqual(albums.last?.trackCount, 2)
        XCTAssertEqual(LibraryModel.albums(library, artist: nil).count, 4)
    }

    func testSongsFollowAlbumOrderDiscThenTrack() {
        let songs = [
            track("B2", artist: "A", album: "X", no: 2, disc: 2),
            track("B1", artist: "A", album: "X", no: 1, disc: 2),
            track("A2", artist: "A", album: "X", no: 2, disc: 1),
            track("A1", artist: "A", album: "X", no: 1, disc: 1),
        ]
        XCTAssertEqual(LibraryModel.songs(songs, artist: nil, album: nil).map(\.title), ["A1", "A2", "B1", "B2"])
    }

    func testSongsFilterByAlbumArtistAndSearch() {
        let album = LibraryModel.albums(library, artist: "The Beatles").first { $0.name == "Abbey Road" }
        XCTAssertEqual(LibraryModel.songs(library, artist: "The Beatles", album: album).map(\.title), ["One", "Two"])
        XCTAssertEqual(LibraryModel.songs(library, artist: "Abba", album: nil).map(\.title), ["Zed"])
        XCTAssertEqual(LibraryModel.songs(library, artist: nil, album: nil, search: "help").map(\.title), ["Help"])
        XCTAssertEqual(LibraryModel.songs(library, artist: nil, album: nil, search: "arrival").map(\.title), ["Zed"])
    }

    func testFilenameParsing() {
        XCTAssertEqual(LibraryModel.trackNumber(fromFilename: "04 - Lies Greed Misery"), 4)
        XCTAssertEqual(LibraryModel.trackNumber(fromFilename: "01. One Time"), 1)
        XCTAssertNil(LibraryModel.trackNumber(fromFilename: "1999 - Song"))
        XCTAssertNil(LibraryModel.trackNumber(fromFilename: "7 Seconds"))
        XCTAssertEqual(LibraryModel.title(fromFilename: URL(fileURLWithPath: "/a/04 - Lies Greed Misery.flac")), "Lies Greed Misery")
        XCTAssertEqual(LibraryModel.title(fromFilename: URL(fileURLWithPath: "/a/7 Seconds.mp3")), "7 Seconds")
    }

    func testTagNumberParsing() {
        XCTAssertEqual(LibraryModel.leadingNumber("4/12"), 4)
        XCTAssertEqual(LibraryModel.leadingNumber("03"), 3)
        XCTAssertNil(LibraryModel.leadingNumber("x"))
        XCTAssertEqual(LibraryModel.year(from: "2009-01-01"), 2009)
        XCTAssertEqual(LibraryModel.year(from: "(1999)"), 1999)
        XCTAssertNil(LibraryModel.year(from: "n/a"))
    }
}

final class FLACTagsTests: XCTestCase {
    private func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }

    private func flac(comments: [String], withPictureFirst: Bool = false) -> Data {
        var bytes = Array("fLaC".utf8)
        // STREAMINFO (type 0), 34 bytes of nothing in particular.
        bytes += [0x00, 0, 0, 34] + [UInt8](repeating: 0, count: 34)
        if withPictureFirst {
            // A big PICTURE block (type 6) that must be skipped, not read.
            bytes += [0x06, 0x00, 0x10, 0x00] + [UInt8](repeating: 7, count: 4096)
        }
        var block = le32(5) + Array("vendr".utf8) + le32(comments.count)
        for c in comments { let u = Array(c.utf8); block += le32(u.count) + u }
        let len = block.count
        bytes += [0x84, UInt8((len >> 16) & 255), UInt8((len >> 8) & 255), UInt8(len & 255)] + block   // last block, type 4
        return Data(bytes)
    }

    private func write(_ data: Data) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).flac")
        try? data.write(to: url)
        return url
    }

    func testReadsFieldsCaseInsensitivelyAndKeepsUnicode() {
        let url = write(flac(comments: ["TITLE=One Time", "artist=Justin Bieber", "ALBUM=Café", "track=1/12", "TITLE=Ignored"]))
        defer { try? FileManager.default.removeItem(at: url) }
        let tags = FLACTags.read(url)
        XCTAssertEqual(tags?["TITLE"], "One Time")
        XCTAssertEqual(tags?["ARTIST"], "Justin Bieber")
        XCTAssertEqual(tags?["ALBUM"], "Café")
        XCTAssertEqual(LibraryModel.leadingNumber(tags?["TRACK"]), 1)
    }

    func testSkipsOtherBlocksBeforeTheComments() {
        let url = write(flac(comments: ["ARTIST=Found"], withPictureFirst: true))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(FLACTags.read(url)?["ARTIST"], "Found")
    }

    func testNotFlacOrTruncatedIsHandled() {
        let junk = write(Data("not a flac file at all".utf8))
        let cut = write(Data(flac(comments: ["ARTIST=X"]).prefix(30)))
        defer { try? FileManager.default.removeItem(at: junk); try? FileManager.default.removeItem(at: cut) }
        XCTAssertNil(FLACTags.read(junk))
        XCTAssertEqual(FLACTags.read(cut)?.count, 0)
        XCTAssertNil(FLACTags.read(URL(fileURLWithPath: "/nonexistent.flac")))
    }

    func testID3LengthCountsTheV24Footer() {
        let head = Data("ID3".utf8) + Data([4, 0, 0x10, 0, 0, 1, 0])
        XCTAssertEqual(ID3Prefix.length(header: head), 10 + 128 + 10)
        let v23 = Data("ID3".utf8) + Data([3, 0, 0x10, 0, 0, 1, 0])
        XCTAssertEqual(ID3Prefix.length(header: v23), 10 + 128)
        XCTAssertNil(ID3Prefix.length(header: Data("fLaC".utf8)))
    }

    func testID3V22AndV24FrameFlagsAreRead() {
        // v2.2: three-letter ids and three-byte sizes.
        let t = Data([0]) + Data("Old".utf8)
        let v22 = Data("TT2".utf8) + Data([0, 0, UInt8(t.count)]) + t
        XCTAssertEqual(ID3Prefix.entries([UInt8](v22), version: 2, flags: 0), ["TITLE=Old"])
        // v2.4 with a data-length indicator, and a compressed frame skipped.
        let a = Data([0, 0, 0, 5]) + Data([3]) + Data("Band".utf8)
        let c = Data([3]) + Data("zzz".utf8)
        let v24 = Data("TPE1".utf8) + Data([0, 0, 0, UInt8(a.count), 0, 0x01]) + a
            + Data("TALB".utf8) + Data([0, 0, 0, UInt8(c.count), 0, 0x08]) + c
        XCTAssertEqual(ID3Prefix.entries([UInt8](v24), version: 4, flags: 0), ["ARTIST=Band"])
    }
}
