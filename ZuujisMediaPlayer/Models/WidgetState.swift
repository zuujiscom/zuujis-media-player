// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the desktop widgets show, and how they talk to the app. This file is
/// compiled into both the app and the widget extension.
///
/// The extension is sandboxed and has no app group (the project signs without
/// a team), so the two exchange files in the app's own Application Support
/// folder, which the extension's entitlements open up:
///
/// - the app writes `widget-state.json` and `widget-art.jpg` whenever
///   something a widget shows changes;
/// - a widget button writes a small `WidgetCommand` file into
///   `widget-commands/`, which the running app picks up, carries out and
///   deletes.
struct WidgetState: Codable, Equatable {
    struct Band: Codable, Equatable { var f: Double; var g: Double }
    struct Lyric: Codable, Equatable { var t: Double; var s: String }

    var hasTrack = false
    var title = ""
    var artist = ""
    var album = ""
    var format = ""
    var isPlaying = false
    var duration = 0.0
    /// Seconds into the song at `anchor`, so a widget can work out where it is
    /// now without being told again: `position + (now - anchor) * speed`.
    var position = 0.0
    var anchor = Date()
    var speed = 1.0
    /// Synced lyrics only; empty otherwise.
    var lyrics: [Lyric] = []

    var eqOn = false
    var bypassed = false
    var preset = ""
    var preampDB = 0.0
    var bands: [Band] = []
    /// Average gain of the low (under 250 Hz), mid and high (over 4 kHz) bands,
    /// which the widget's tone buttons nudge a dB at a time.
    var bass = 0.0
    var mid = 0.0
    var treble = 0.0
    /// Every preset's name, built-in first, for the widget's preset buttons.
    var presets: [String] = []

    /// Where the song is at `date`.
    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        return min(duration, max(0, position + date.timeIntervalSince(anchor) * speed))
    }

    /// The lyric line being sung at `time`, or nil before the first.
    func lyricIndex(at time: Double) -> Int? {
        var low = 0, high = lyrics.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].t <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }
}

struct WidgetCommand: Codable {
    /// `playPause`, `next`, `previous`, `eqPower`, `eqBypass`, `nextPreset`,
    /// `preamp` (arg: dB step, 0 resets), `tone` (arg: `bass`/`mid`/`treble`,
    /// amount: dB step), `flat` or `preset` (arg: the preset's name).
    var name: String
    var arg: String?
    var amount: Double?
}

enum WidgetFiles {
    /// The app sets this to its data folder (which honours the debug data-dir
    /// override); the sandboxed extension works the real one out.
    nonisolated(unsafe) static var folderOverride: URL?

    static var folder: URL {
        if let folderOverride { return folderOverride }
        // In a sandbox `homeDirectoryForCurrentUser` is the container; the
        // password database still has the real home.
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Zuujis Media Player", isDirectory: true)
    }

    static var state: URL { folder.appendingPathComponent("widget-state.json") }
    static var art: URL { folder.appendingPathComponent("widget-art.jpg") }
    static var commands: URL { folder.appendingPathComponent("widget-commands", isDirectory: true) }

    static func loadState() -> WidgetState? {
        guard let data = try? Data(contentsOf: state) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetState.self, from: data)
    }

    static func write(_ state: WidgetState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: Self.state, options: .atomic)
    }

    static func send(_ command: WidgetCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        try? FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try? data.write(to: commands.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
    }
}
