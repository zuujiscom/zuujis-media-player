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
    /// The presets the widget offers, in the order chosen in Settings (every
    /// preset, built-in first, when none were chosen).
    var presets: [String] = []

    // Added later. Optional, so a widget and an app of different builds can
    // still read each other's file.
    /// Whether the playing song is in Favorites.
    var favorite: Bool?
    /// How the widgets are laid out; nil means the defaults.
    var settings: WidgetSettings?

    var layout: WidgetSettings { settings ?? WidgetSettings() }

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

/// The user's choices for the desktop widgets, edited in the app's Settings
/// and handed to the widgets inside `WidgetState`. Every field decodes with a
/// default, so adding one never breaks an older file.
struct WidgetSettings: Codable, Equatable {
    static let sizes = ["compact", "regular", "large"]

    // Equalizer widget
    /// The presets on the widget, by name and in order. Empty means all.
    var eqPresets: [String] = []
    /// What the small widget shows under its header: `preamp` or `presets`.
    var eqSmall = "preamp"
    /// What the medium widget shows: `tone` (bass/mid/treble/preamp) or `presets`.
    var eqMedium = "tone"
    /// Whether the large widget has the tone steppers above its presets.
    var eqLargeTone = true
    /// Large widget: presets above the tone steppers instead of below.
    var eqPresetsFirst = false
    /// Preset buttons per row on the medium and large widgets (2 to 4).
    var eqColumns = 3
    /// What one tap of − or + changes, in dB.
    var eqStep = 1.0
    /// Size of the buttons and text: `compact`, `regular` or `large`.
    var eqSize = "regular"

    // Now Playing widget
    /// The lyric line on the medium widget.
    var npMediumLyrics = true
    /// What fills the large widget: `lyrics` or `cover`.
    var npLarge = "lyrics"
    /// Lyric text size: `compact`, `regular` or `large`.
    var npLyricSize = "regular"
    var npSkipButtons = true
    var npTime = true
    var npFavorite = true
    /// The cover, blurred, as the widget's backdrop.
    var npCoverBackdrop = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = WidgetSettings()
        eqPresets = get(.eqPresets, d.eqPresets)
        eqSmall = get(.eqSmall, d.eqSmall)
        eqMedium = get(.eqMedium, d.eqMedium)
        eqLargeTone = get(.eqLargeTone, d.eqLargeTone)
        eqPresetsFirst = get(.eqPresetsFirst, d.eqPresetsFirst)
        eqColumns = min(4, max(2, get(.eqColumns, d.eqColumns)))
        eqStep = min(6, max(0.5, get(.eqStep, d.eqStep)))
        eqSize = get(.eqSize, d.eqSize)
        npMediumLyrics = get(.npMediumLyrics, d.npMediumLyrics)
        npLarge = get(.npLarge, d.npLarge)
        npLyricSize = get(.npLyricSize, d.npLyricSize)
        npSkipButtons = get(.npSkipButtons, d.npSkipButtons)
        npTime = get(.npTime, d.npTime)
        npFavorite = get(.npFavorite, d.npFavorite)
        npCoverBackdrop = get(.npCoverBackdrop, d.npCoverBackdrop)
    }

    /// 0.88, 1 or 1.14 for `compact`, `regular`, `large`.
    static func factor(_ size: String) -> Double {
        size == "compact" ? 0.88 : (size == "large" ? 1.14 : 1)
    }

    /// The presets the widget offers out of `all`: the chosen ones that still
    /// exist, in the chosen order, or all of them when none were chosen.
    func offeredPresets(from all: [String]) -> [String] {
        let chosen = eqPresets.filter(all.contains)
        return chosen.isEmpty ? all : chosen
    }

    /// "+4", "-1.5", or a bare "0" for anything that rounds to nothing.
    static func signed(_ value: Double, places: Int) -> String {
        let unit = pow(10, Double(places))
        let shown = (value * unit).rounded() / unit
        return shown == 0 ? "0" : String(format: "%+.\(places)f", shown)
    }

    /// How many rows of `rowHeight` fit in `height` with `spacing` between.
    static func rows(in height: Double, rowHeight: Double, spacing: Double) -> Int {
        max(0, Int(((height + spacing) / (rowHeight + spacing)).rounded(.down)))
    }
}

struct WidgetCommand: Codable {
    /// `playPause`, `next`, `previous`, `favorite`, `eqPower`, `eqBypass`,
    /// `nextPreset`, `preamp` (amount: dB step, 0 resets), `tone` (arg:
    /// `bass`/`mid`/`treble`, amount: dB step), `flat` or `preset` (arg: the
    /// preset's name).
    var name: String
    var arg: String?
    var amount: Double?
    /// When the button was pressed. A press the app was not running for is
    /// dropped rather than carried out at the next launch.
    var sent: Date? = Date()
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
