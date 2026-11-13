import XCTest
@testable import ZuujisCore

final class LyricsTests: XCTestCase {
    func testParsesSyncedLines() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("[ar:Someone]\n[00:12.50]First\n[00:05.00]Zero\n[01:02.25]Last"))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Zero", "First", "Last"])
        XCTAssertEqual(lyrics.lines.map(\.time), [5.0, 12.5, 62.25])
    }

    func testRepeatedStampsAndWordStamps() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("[00:10.00][00:30.00]Chorus <00:10.20>line"))
        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Chorus line", "Chorus line"])
        XCTAssertEqual(lyrics.lines.map(\.time), [10, 30])
    }

    func testOffsetShiftsEarlier() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("[offset:+500]\n[00:10.00]A"))
        XCTAssertEqual(lyrics.lines[0].time ?? 0, 9.5, accuracy: 0.001)
    }

    func testCurrentIndex() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("[00:05.00]A\n[00:10.00]B\n[00:20.00]C"))
        XCTAssertNil(lyrics.currentIndex(at: 1))
        XCTAssertEqual(lyrics.currentIndex(at: 5), 0)
        XCTAssertEqual(lyrics.currentIndex(at: 15), 1)
        XCTAssertEqual(lyrics.currentIndex(at: 999), 2)
    }

    func testPlainText() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("One\r\n\r\n\r\nTwo\n\n"))
        XCTAssertFalse(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["One", "", "Two"])
        XCTAssertNil(lyrics.currentIndex(at: 3))
    }

    func testEmpty() {
        XCTAssertNil(Lyrics.parse(""))
        XCTAssertNil(Lyrics.parse("[ar:Nobody]\n[ti:Nothing]"))
    }
}
