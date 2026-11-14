// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Matches recognised words to lyric lines. Pure, so it is unit-tested.
enum LyricsAligner {
    struct Word: Equatable {
        var time: Double
        var text: String
        /// How long the recognizer says the word lasts (0 = unknown). A very
        /// long one includes a silence, often before the word itself.
        var duration: Double = 0
    }

    /// How far ahead of its first sung word a line is shown.
    static let lead = 0.15

    static func norm(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    struct Timing: Equatable {
        /// Each line's start; nil for blank lines.
        var lines: [Double?]
        /// Each line's words (split on spaces) with their start times.
        var words: [[LyricWord]]
        /// Which lines had sung words recognised (the rest were estimated).
        var heard: [Bool] = []
    }

    /// Times every line and word. A word the recognizer heard takes its time;
    /// a line starts at its first sung word, stepping back over misheard
    /// words just before the first recognised one ("Lolita" heard as
    /// "lonely"); unheard words are spread between their neighbours.
    static func align(lines: [String], heard: [Word]) -> Timing {
        align(lines: lines, passes: [heard])
    }

    /// The same from several listening passes over the same song (the file
    /// as it is, its channels mixed down, a voice-band copy: each hears
    /// words the others miss). Every line takes the pass that recognised
    /// most of it, and the other passes fill in words that one missed.
    static func align(lines: [String], passes: [[Word]]) -> Timing {
        let lineWords = lines.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        let wordLines = lines.indices.filter { !lineWords[$0].isEmpty }
        let results = passes.compactMap { match(lineWords: lineWords, heard: $0) }
        guard !results.isEmpty else { return Timing(lines: lines.map { _ in nil }, words: lineWords.map { _ in [] }) }

        var starts = [Double?](repeating: nil, count: lines.count)
        var known = lineWords.map { [Double?](repeating: nil, count: $0.count) }
        var heardLine = [Bool](repeating: false, count: lines.count)
        for line in wordLines {
            var best: Int?
            for (p, result) in results.enumerated() where result.count[line] > 0 {
                guard let b = best else { best = p; continue }
                let other = results[b]
                if result.count[line] > other.count[line]
                    || (result.count[line] == other.count[line] && result.opened[line] && !other.opened[line]) { best = p }
            }
            guard let best, var start = results[best].starts[line] else { continue }
            known[line] = results[best].known[line]
            heardLine[line] = true
            // The best pass missed the line's opening words but another heard
            // them: start where that one did.
            if !results[best].opened[line], let firstKnown = known[line].compactMap({ $0 }).first {
                let opening = results.filter { $0.opened[line] }.compactMap { $0.starts[line] }
                    .first { $0 < firstKnown && $0 > firstKnown - 6 }
                if let opening { start = opening }
            }
            starts[line] = start
            // Words this pass missed, where another pass heard them in order.
            for (p, result) in results.enumerated() where p != best {
                var lower = start
                for slot in known[line].indices {
                    if let t = known[line][slot] { lower = t; continue }
                    guard let t = result.known[line][slot], t >= lower else { continue }
                    if let upper = known[line][(slot + 1)...].compactMap({ $0 }).first, t > upper { continue }
                    known[line][slot] = t
                    lower = t
                }
            }
        }
        // A line no pass recognised takes the first pass's guess (the stray
        // heard words between its neighbours) when that still fits.
        for (position, line) in wordLines.enumerated() where starts[line] == nil {
            guard let guess = results[0].starts[line] else { continue }
            let before = wordLines[..<position].last { starts[$0] != nil }
            let after = wordLines[(position + 1)...].first { starts[$0] != nil }
            let low = before.map { known[$0].compactMap { $0 }.max() ?? starts[$0]! } ?? -1
            let high = after.flatMap { starts[$0] } ?? .infinity
            if guess > low, guess < high { starts[line] = guess }
        }
        for (position, line) in wordLines.enumerated() where starts[line] == nil {
            let before = wordLines[..<position].last { starts[$0] != nil }.flatMap { starts[$0] }
            let after = wordLines[(position + 1)...].first { starts[$0] != nil }.flatMap { starts[$0] }
            switch (before, after) {
            case let (b?, a?): starts[line] = (b + a) / 2
            case let (b?, nil): starts[line] = b + 3
            case let (nil, a?): starts[line] = max(0, a - 3)
            default: starts[line] = 0
            }
        }
        var last = -Double.infinity
        for line in wordLines {
            if let t = starts[line], t <= last { starts[line] = last + 0.5 }
            last = starts[line] ?? last
        }

        // Word times: heard where matched, the line's start for its first word,
        // the rest spread evenly between known neighbours.
        var words = lineWords.map { _ in [LyricWord]() }
        for (position, line) in wordLines.enumerated() {
            guard let start = starts[line] else { continue }
            let end = wordLines.indices.contains(position + 1) ? (starts[wordLines[position + 1]] ?? start + 4) : start + 4
            var times = known[line]
            times[0] = start
            var previous = start
            for slot in times.indices {
                // A matched time out of order (or past the next line) is not trusted.
                if let t = times[slot], t >= previous, t < end { previous = t } else { times[slot] = nil }
            }
            times[0] = start
            var slot = 0
            while slot < times.count {
                guard times[slot] == nil else { slot += 1; continue }
                let from = slot - 1
                var to = slot
                while to < times.count, times[to] == nil { to += 1 }
                let a = times[from]!
                // Unheard words at the end share the time until about a second
                // after the last one, never into the next line.
                let b = to < times.count ? times[to]! : min(end, a + 0.45 * Double(to - from))
                for k in slot..<to { times[k] = a + (b - a) * Double(k - from) / Double(to - from) }
                slot = to
            }
            words[line] = zip(lineWords[line], times).map { LyricWord(time: $1!, text: $0) }
        }
        return Timing(lines: starts, words: words, heard: heardLine)
    }

    /// One listening pass matched to the lyrics.
    private struct Pass {
        /// Line starts: where the line's words were heard, or for a line with
        /// none, the stray heard words between its neighbours (a guess).
        var starts: [Double?]
        /// Matched word times by line and word slot.
        var known: [[Double?]]
        /// How many of each line's words were recognised.
        var count: [Int]
        /// Whether the line's start is a heard word rather than backed up
        /// from a later one.
        var opened: [Bool]
    }

    private static func match(lineWords: [[String]], heard rawHeard: [Word]) -> Pass? {
        let heard = rawHeard.compactMap { w -> Word? in
            let n = norm(w.text); return n.isEmpty ? nil : Word(time: w.time, text: n, duration: w.duration)
        }
        var lyric: [(line: Int, slot: Int, word: String)] = []
        for (index, words) in lineWords.enumerated() {
            for (slot, piece) in words.enumerated() {
                let n = norm(piece)
                if !n.isEmpty { lyric.append((index, slot, n)) }
            }
        }
        let n = lyric.count, m = heard.count
        let wordLines = lineWords.indices.filter { !lineWords[$0].isEmpty }
        guard n > 0, m > 0 else { return nil }

        // Longest common subsequence, weighted: exact words 3, near misses 1.
        func score(_ a: String, _ b: String) -> Int {
            if a == b { return 3 }
            if a.count >= 4, b.count >= 4, a.prefix(3) == b.prefix(3) { return 1 }
            return 0
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                let s = score(lyric[i].word, heard[j].text)
                table[i][j] = max(table[i + 1][j], table[i][j + 1], s > 0 ? s + table[i + 1][j + 1] : 0)
            }
        }
        var heardFor = [Int?](repeating: nil, count: n)
        var i = 0, j = 0
        while i < n, j < m {
            let s = score(lyric[i].word, heard[j].text)
            if s > 0, table[i][j] == s + table[i + 1][j + 1] { heardFor[i] = j; i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }

        // Each line's matches in order: (word slot, heard index).
        var matches = lineWords.map { _ in [(slot: Int, heard: Int)]() }
        for (k, h) in heardFor.enumerated() { if let h { matches[lyric[k].line].append((lyric[k].slot, h)) } }
        // A line's anchor is its first match that the next match follows
        // closely; a lone common word well before the rest ("and" misheard
        // from the line before) does not mark where the line starts.
        var firstHeard = [Int?](repeating: nil, count: lineWords.count)
        var firstSlot = [Int](repeating: 0, count: lineWords.count)
        var lastHeard = [Int?](repeating: nil, count: lineWords.count)
        var known = lineWords.map { [Double?](repeating: nil, count: $0.count) }
        var count = [Int](repeating: 0, count: lineWords.count)
        for line in lineWords.indices where !matches[line].isEmpty {
            let list = matches[line]
            var anchor = 0
            while anchor + 1 < list.count, heard[list[anchor + 1].heard].time - heard[list[anchor].heard].time > 1.5 {
                anchor += 1
            }
            firstHeard[line] = list[anchor].heard
            firstSlot[line] = list[anchor].slot
            lastHeard[line] = list.last!.heard
            // Matches before the anchor are not this line's words.
            for item in list[anchor...] { known[line][item.slot] = heard[item.heard].time }
            count[line] = list.count - anchor
        }

        // Line starts.
        var starts = [Double?](repeating: nil, count: lineWords.count)
        var opened = [Bool](repeating: false, count: lineWords.count)
        var previousEnd = -1
        for (position, line) in wordLines.enumerated() {
            let nextMatched = wordLines[(position + 1)...].lazy.compactMap { firstHeard[$0] }.first ?? m
            if let first = firstHeard[line] {
                // Step back over unmatched words sung just before (each within
                // 2.5 s of the next, at most 4 s in all, and not one stretched
                // over a silence, whose own start is unreliable), no more of them than
                // the line has words before its anchor.
                var start = first
                while first - start < firstSlot[line], start - 1 > previousEnd,
                      heard[start].time - heard[start - 1].time < 2.5, heard[start - 1].duration < 1.5,
                      heard[first].time - heard[start - 1].time < 4 { start -= 1 }
                // Opening words not heard at all (fewer stepped-back words than
                // words before the anchor): back up about 0.32 s for each,
                // not past the line before.
                let missing = firstSlot[line] - (first - start)
                let floor = previousEnd >= 0 ? heard[previousEnd].time + 0.3 : 0
                starts[line] = missing > 0 ? max(floor, heard[start].time - 0.32 * Double(missing)) : heard[start].time
                opened[line] = missing <= 0
                previousEnd = max(previousEnd, lastHeard[line] ?? first)
            } else if previousEnd + 1 < nextMatched {
                starts[line] = heard[previousEnd + 1].time
                previousEnd += 1
            }
        }
        return Pass(starts: starts, known: known, count: count, opened: opened)
    }

    /// Word times for lyrics whose lines are already timed (LRCLIB or a .lrc).
    /// Those line times are often a second or more off (another cut's timing,
    /// or simply sloppy), so the whole song is aligned as for untimed lyrics
    /// and a line moves to where it is actually sung when its words were
    /// recognised there, within `maxShift` of its stated time after the
    /// song's typical offset is allowed for. Lines with nothing recognisable,
    /// and empty break lines, keep their stated time plus that offset.
    static let maxShift = 6.0

    static func alignWords(timedLines: [(time: Double, text: String)], heard: [Word]) -> Timing {
        alignWords(timedLines: timedLines, passes: [heard])
    }

    static func alignWords(timedLines: [(time: Double, text: String)], passes: [[Word]]) -> Timing {
        let texts = timedLines.map(\.text)
        var global = align(lines: texts, passes: passes)
        let heardLine = global.heard.count == texts.count ? global.heard : texts.map { _ in false }

        // The song's typical offset between stated and sung times (median).
        var offsets: [Double] = []
        for (index, line) in timedLines.enumerated() where heardLine[index] {
            if let t = global.lines[index], abs(t - line.time) < 8 { offsets.append(t - line.time) }
        }
        offsets.sort()
        let typical = offsets.isEmpty ? 0 : offsets[offsets.count / 2]

        var starts: [Double?] = []
        var words: [[LyricWord]] = []
        var trusted: [Bool] = []
        for (index, line) in timedLines.enumerated() {
            let stated = line.time + typical
            let pieces = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
            if pieces.isEmpty {
                // An empty timed line marks a break (shown as ♪).
                starts.append(stated); words.append([]); trusted.append(false); continue
            }
            if heardLine[index], let sung = global.lines[index], abs(sung - stated) <= maxShift {
                starts.append(sung); words.append(global.words[index]); trusted.append(true)
            } else {
                starts.append(stated); words.append([]); trusted.append(false)
            }
        }
        // Always moving forward; then spread the words of estimated lines over
        // the start of their span.
        var last = -Double.infinity
        for index in starts.indices {
            guard var t = starts[index] else { continue }
            if t <= last { t = last + 0.3; starts[index] = t }
            last = t
        }
        for index in starts.indices where !trusted[index] {
            let pieces = timedLines[index].text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !pieces.isEmpty, let start = starts[index] else { continue }
            let next = starts[(index + 1)...].lazy.compactMap { $0 }.first ?? start + 8
            let span = min(max(0.3, next - start - 0.2), 0.45 * Double(pieces.count))
            words[index] = pieces.enumerated().map { k, text in
                LyricWord(time: start + span * Double(k) / Double(pieces.count), text: text)
            }
        }
        // A trusted line's words must not run past the next line's start.
        for index in starts.indices where trusted[index] {
            guard let next = starts[(index + 1)...].lazy.compactMap({ $0 }).first else { continue }
            words[index] = words[index].map { LyricWord(time: min($0.time, next - 0.05), text: $0.text) }
        }
        global.lines = starts
        global.words = words
        global.heard = trusted
        return global
    }

    /// Enhanced LRC: `[mm:ss.xx]<mm:ss.xx>word <mm:ss.xx>word`, each stamp a
    /// little ahead of the word so it lights as it is sung.
    static func lrc(lines: [String], timing: Timing) -> String {
        func stamp(_ time: Double) -> String {
            let t = max(0, time - lead)
            return String(format: "%02d:%05.2f", Int(t / 60), t.truncatingRemainder(dividingBy: 60))
        }
        return lines.indices.map { index -> String in
            guard let start = timing.lines[index] else { return "" }
            let words = timing.words[index]
            if words.isEmpty { return "[\(stamp(start))]" + lines[index] }
            return "[\(stamp(start))]" + words.map { "<\(stamp($0.time))>\($0.text)" }.joined(separator: " ")
        }.joined(separator: "\n") + "\n"
    }
}
