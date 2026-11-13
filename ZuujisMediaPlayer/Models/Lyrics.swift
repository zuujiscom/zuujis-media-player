// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One line of a song's lyrics. `time` is seconds into the track for a synced
/// (LRC) line and nil for plain text.
struct LyricLine: Equatable, Identifiable {
    let id: Int
    let time: Double?
    let text: String
}

/// A song's lyrics, either synced (an LRC file or LRC text in a tag: every
/// line has a time) or plain. Pure parsing and lookup, no I/O — the file and
/// tag reading is in `LyricsStore`.
struct Lyrics: Equatable {
    var lines: [LyricLine]
    var isSynced: Bool

    /// Reads LRC (`[01:23.45]text`, several stamps per line, an `[offset:ms]`
    /// tag, enhanced `<01:23.45>` word stamps dropped) or, when no line has a
    /// stamp, plain text. nil when there is nothing to show.
    static func parse(_ raw: String) -> Lyrics? {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var offset = 0.0
        var timed: [(time: Double, text: String)] = []
        var plain: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            let original = String(line)
            var stamps: [Double] = []
            var isMetadata = false

            // Leading [..] groups: time stamps, or ID tags such as [ar:Artist].
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = String(line[line.index(after: line.startIndex)..<close])
                if let seconds = stamp(tag) {
                    stamps.append(seconds)
                } else if let colon = tag.firstIndex(of: ":"), !tag[..<colon].isEmpty {
                    if tag[..<colon].lowercased() == "offset",
                       let ms = Double(tag[tag.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                        offset = ms / 1000
                    }
                    isMetadata = true
                } else {
                    break
                }
                line = line[line.index(after: close)...]
            }

            if stamps.isEmpty {
                if !isMetadata { plain.append(original) }
            } else {
                let words = removingWordStamps(String(line)).trimmingCharacters(in: .whitespaces)
                for time in stamps { timed.append((time, words)) }
            }
        }

        if !timed.isEmpty {
            // Stable by time: lines sharing a stamp keep their order.
            let sorted = timed.enumerated()
                .map { (time: max(0, $0.element.time - offset), index: $0.offset, text: $0.element.text) }
                .sorted { ($0.time, $0.index) < ($1.time, $1.index) }
            return Lyrics(lines: sorted.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) },
                          isSynced: true)
        }

        // Plain: collapse runs of blank lines, trim the blank edges.
        var lines: [String] = []
        for line in plain {
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return Lyrics(lines: lines.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) },
                      isSynced: false)
    }

    /// The line being sung at `time`: the last one that has started. nil
    /// before the first line, or for plain lyrics.
    func currentIndex(at time: Double) -> Int? {
        guard isSynced else { return nil }
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if let t = lines[mid].time, t <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// `mm:ss`, `mm:ss.xx` or `h:mm:ss.xx` as seconds; nil for anything else
    /// (`ar:Artist`).
    private static func stamp(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber || $0 == "." }), let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private static func removingWordStamps(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return text.replacingOccurrences(of: #"<\d{1,2}:\d{2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "  ", with: " ")
    }
}
