// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ZuujisCore

final class TagEditTests: XCTestCase {
    private func track() -> LibraryTrack {
        LibraryTrack(url: URL(fileURLWithPath: "/m/04 - Song.flac"), title: "Song", artist: "Old", album: "LP",
                     genre: "Rock", trackNumber: 4, discNumber: 1, year: 1999, duration: 10,
                     size: 1, modified: Date(timeIntervalSince1970: 0))
    }

    func testSetsOnlyTheFieldsGiven() {
        let t = TagEdit(artist: "New").apply(to: track())
        XCTAssertEqual(t.artist, "New")
        XCTAssertEqual(t.album, "LP")
        XCTAssertEqual(t.genre, "Rock")
    }

    func testEmptyClearsAndTitleFallsBackToFilename() {
        let t = TagEdit(title: "", artist: "  ", genre: "", year: 0).apply(to: track())
        XCTAssertNil(t.artist)
        XCTAssertNil(t.genre)
        XCTAssertNil(t.year)
        XCTAssertEqual(t.title, "Song")
    }

    func testMergeLetsNewerWin() {
        let merged = TagEdit(artist: "A", album: "B").merged(with: TagEdit(artist: "C", genre: "G"))
        XCTAssertEqual(merged, TagEdit(artist: "C", album: "B", genre: "G"))
    }

    func testEmptyEditIsEmpty() {
        XCTAssertTrue(TagEdit().isEmpty)
        XCTAssertFalse(TagEdit(year: 0).isEmpty)
    }

    func testSearchMatchesGenre() {
        let found = LibraryModel.songs([track()], artist: nil, album: nil, search: "rock")
        XCTAssertEqual(found.count, 1)
    }
}
