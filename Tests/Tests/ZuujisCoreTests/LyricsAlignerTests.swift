import XCTest
@testable import ZuujisCore

final class LyricsAlignerTests: XCTestCase {
    private func heard(_ pairs: [(Double, String)]) -> [LyricsAligner.Word] {
        pairs.map { LyricsAligner.Word(time: $0.0, text: $0.1) }
    }

    func testParsesWordStamps() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("[00:10.00]<00:10.00>Hello <00:10.80>there <00:11.50>world"))
        let line = lyrics.lines[0]
        XCTAssertEqual(line.text, "Hello there world")
        XCTAssertEqual(line.words?.map(\.text), ["Hello", "there", "world"])
        XCTAssertEqual(line.wordsSung(at: 9), 0)
        XCTAssertEqual(line.wordsSung(at: 10.9), 2)
        XCTAssertEqual(line.wordsSung(at: 99), 3)
    }

    func testRepeatedLineStampsKeepNoWordTimes() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("[00:10.00][00:30.00]Chorus <00:10.20>line"))
        XCTAssertNil(lyrics.lines[0].words)
    }

    func testAlignsLinesAndWords() {
        let lines = ["Hello there world", "", "Second line here"]
        let timing = LyricsAligner.align(lines: lines, heard: heard([
            (5.0, "Hello"), (5.5, "there"), (6.0, "world."), (9.0, "Second"), (9.4, "line"), (9.9, "here"),
        ]))
        XCTAssertEqual(timing.lines[0], 5.0)
        XCTAssertNil(timing.lines[1])
        XCTAssertEqual(timing.lines[2], 9.0)
        XCTAssertEqual(timing.words[2].map(\.time), [9.0, 9.4, 9.9])
    }

    func testMisheardOpeningWordStillStartsTheLine() {
        // "Lolita" heard as "lonely": the line starts at the misheard word.
        let lines = ["The pizza was me", "Lolita Lolita Express", "Took me up"]
        let timing = LyricsAligner.align(lines: lines, heard: heard([
            (70, "the"), (71, "pizza"), (71.4, "was"), (72.5, "me"),
            (73.1, "lonely"), (75.3, "lonely"), (75.9, "express"), (78.2, "took"), (78.5, "me"), (78.9, "up"),
        ]))
        XCTAssertEqual(timing.lines[1], 73.1)
        XCTAssertEqual(timing.words[1].count, 3)
        XCTAssertEqual(timing.words[1].last?.time, 75.9)
    }

    func testUnheardLineSitsBetweenNeighbours() {
        let lines = ["One two", "Unheard words", "Three four"]
        let timing = LyricsAligner.align(lines: lines, heard: heard([(1, "one"), (1.5, "two"), (9, "three"), (9.5, "four")]))
        let middle = timing.lines[1] ?? 0
        XCTAssertGreaterThan(middle, 1.5)
        XCTAssertLessThan(middle, 9)
    }

    func testWritesEnhancedLRCThatReadsBack() throws {
        let lines = ["Hello there"]
        let timing = LyricsAligner.align(lines: lines, heard: heard([(5, "hello"), (6, "there")]))
        let lrc = LyricsAligner.lrc(lines: lines, timing: timing)
        let lyrics = try XCTUnwrap(Lyrics.parse(lrc))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines[0].text, "Hello there")
        XCTAssertEqual(lyrics.lines[0].words?.count, 2)
    }
}
