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

final class LyricsAlignerAnchoredTests: XCTestCase {
    private func words(_ pairs: [(Double, String)]) -> [LyricsAligner.Word] {
        pairs.map { LyricsAligner.Word(time: $0.0, text: $0.1) }
    }

    func testLinesMoveToWhereTheyAreSung() {
        // Stated times run 2 s early, as LRCLIB's did for "Time After Time".
        let lines: [(time: Double, text: String)] = [(10, "Chorus goes here"), (14, "Verse line now"), (20, "Chorus goes here")]
        let timing = LyricsAligner.alignWords(timedLines: lines, heard: words([
            (12.0, "chorus"), (12.6, "goes"), (13.1, "here"), (16.0, "verse"), (16.5, "line"), (16.9, "now"),
            (22.0, "chorus"), (22.5, "goes"), (23.4, "here"),
        ]))
        XCTAssertEqual(timing.lines, [12, 16, 22])
        // The second chorus uses its own words, not the first one's.
        XCTAssertEqual(timing.words[2].map(\.time), [22, 22.5, 23.4])
    }

    func testUnrecognisedLineTakesTheSongsOffset() {
        let lines: [(time: Double, text: String)] = [(10, "One two three"), (14, "Mumbled words here"), (20, "Four five six")]
        let timing = LyricsAligner.alignWords(timedLines: lines, heard: words([
            (11.5, "one"), (12, "two"), (12.5, "three"), (21.5, "four"), (22, "five"), (22.5, "six"),
        ]))
        XCTAssertEqual(timing.lines[1] ?? 0, 15.5, accuracy: 0.001)
    }

    func testAStrayMatchFarAwayIsIgnored() {
        // "time" heard 30 s away must not drag the line there.
        let lines: [(time: Double, text: String)] = [(10, "Time"), (12, "After all")]
        let timing = LyricsAligner.alignWords(timedLines: lines, heard: words([(40, "time"), (12.1, "after"), (12.4, "all")]))
        XCTAssertLessThan(timing.lines[0] ?? 99, 12)
    }

    func testKeepsInstrumentalBreaks() throws {
        let lines: [(time: Double, text: String)] = [(5, "Sung"), (8, ""), (12, "Again")]
        let timing = LyricsAligner.alignWords(timedLines: lines, heard: [])
        let lyrics = try XCTUnwrap(Lyrics.parse(LyricsAligner.lrc(lines: lines.map(\.text), timing: timing)))
        XCTAssertEqual(lyrics.lines.count, 3)
        XCTAssertEqual(lyrics.lines[1].text, "")
    }

    func testUnheardLineStillGetsWordTimes() {
        let timing = LyricsAligner.alignWords(timedLines: [(5, "Nothing heard here"), (9, "Next")], heard: [])
        XCTAssertEqual(timing.words[0].count, 3)
        XCTAssertEqual(timing.words[0].first?.time, 5)
        XCTAssertLessThan(timing.words[0].last?.time ?? 99, 9)
    }
}

final class LyricsAlignerMishearingTests: XCTestCase {
    private func words(_ pairs: [(Double, String)]) -> [LyricsAligner.Word] {
        pairs.map { LyricsAligner.Word(time: $0.0, text: $0.1) }
    }

    func testLoneLeadingMatchDoesNotStartTheLine() {
        // "if I'm okay" heard as "and I okay": that "and" must not start the
        // next line, "And you say go slow", sung 2.5 s later.
        let lines = ["Wondering if I'm okay", "And you say go slow"]
        let timing = LyricsAligner.align(lines: lines, heard: words([
            (130.8, "wondering"), (131.9, "and"), (133.1, "I"), (133.6, "okay"),
            (134.4, "when"), (134.7, "you"), (135.0, "say"), (135.4, "go"), (135.8, "slow"),
        ]))
        XCTAssertGreaterThan(timing.lines[1] ?? 0, 133.6)
    }

    func testMissedOpeningWordsBackUpTheStart() {
        // Only "darkness" was recognised, five words into the line.
        let lines = ["Time after time", "After my picture fades our darkness has turned"]
        let timing = LyricsAligner.align(lines: lines, heard: words([
            (100, "time"), (100.5, "after"), (101, "time"), (124.0, "darkness"), (125.0, "has"), (125.5, "turned"),
        ]))
        let start = timing.lines[1] ?? 0
        XCTAssertLessThan(start, 123)
        XCTAssertGreaterThan(start, 120)
    }
}
