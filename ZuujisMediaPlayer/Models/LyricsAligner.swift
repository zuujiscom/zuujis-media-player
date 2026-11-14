// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Matches recognised words to lyric lines. Pure, so it is unit-tested.
enum LyricsAligner {
    struct Word: Equatable {
        var time: Double
        var text: String
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
    }

    /// Times every line and word. A word the recognizer heard takes its time;
    /// a line starts at its first sung word, stepping back over misheard
    /// words just before the first recognised one ("Lolita" heard as
    /// "lonely"); unheard words are spread between their neighbours.
    static func align(lines: [String], heard rawHeard: [Word]) -> Timing {
        let heard = rawHeard.compactMap { w -> Word? in
            let n = norm(w.text); return n.isEmpty ? nil : Word(time: w.time, text: n)
        }
        let lineWords = lines.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        var lyric: [(line: Int, slot: Int, word: String)] = []
        for (index, words) in lineWords.enumerated() {
            for (slot, piece) in words.enumerated() {
                let n = norm(piece)
                if !n.isEmpty { lyric.append((index, slot, n)) }
            }
        }
        let n = lyric.count, m = heard.count
        let wordLines = lines.indices.filter { !lineWords[$0].isEmpty }
        guard n > 0, m > 0 else { return Timing(lines: lines.map { _ in nil }, words: lineWords.map { _ in [] }) }

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

        var firstHeard = [Int?](repeating: nil, count: lines.count)
        var lastHeard = [Int?](repeating: nil, count: lines.count)
        for (k, h) in heardFor.enumerated() {
            guard let h else { continue }
            let line = lyric[k].line
            if firstHeard[line] == nil { firstHeard[line] = h }
            lastHeard[line] = h
        }

        // Line starts.
        var starts = [Double?](repeating: nil, count: lines.count)
        var previousEnd = -1
        for (position, line) in wordLines.enumerated() {
            let nextMatched = wordLines[(position + 1)...].lazy.compactMap { firstHeard[$0] }.first ?? m
            if let first = firstHeard[line] {
                // Step back over unmatched words sung just before (each within
                // 2.5 s of the next, at most 4 s in all).
                var start = first
                while start - 1 > previousEnd,
                      heard[start].time - heard[start - 1].time < 2.5,
                      heard[first].time - heard[start - 1].time < 4 { start -= 1 }
                starts[line] = heard[start].time
                previousEnd = max(previousEnd, lastHeard[line] ?? first)
            } else if previousEnd + 1 < nextMatched {
                starts[line] = heard[previousEnd + 1].time
                previousEnd += 1
            }
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
        var known = lineWords.map { [Double?](repeating: nil, count: $0.count) }
        for (k, h) in heardFor.enumerated() { if let h { known[lyric[k].line][lyric[k].slot] = heard[h].time } }
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
        return Timing(lines: starts, words: words)
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
