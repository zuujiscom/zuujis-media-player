// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import Foundation

// Each widget button hands the running app a command (see `WidgetFiles`); the
// app carries it out and refreshes the widgets. They run in the extension,
// which is sandboxed, so they cannot touch the player directly.

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "playPause")); return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "next")); return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "previous")); return .result()
    }
}

struct FavoriteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to or Remove from Favorites"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "favorite")); return .result()
    }
}

struct EQPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Equalizer On or Off"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "eqPower")); return .result()
    }
}

struct EQBypassIntent: AppIntent {
    static let title: LocalizedStringResource = "Bypass the Equalizer"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "eqBypass")); return .result()
    }
}

struct NextPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Equalizer Preset"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "nextPreset")); return .result()
    }
}

struct PreampIntent: AppIntent {
    static let title: LocalizedStringResource = "Change the Preamp"
    static let isDiscoverable = false
    @Parameter(title: "Step in dB (0 resets)") var step: Double
    init() { step = 0 }
    init(step: Double) { self.step = step }
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "preamp", amount: step)); return .result()
    }
}

/// One intent for every tone control, so a button is `ToneIntent(...)`.
struct ToneIntent: AppIntent {
    static let title: LocalizedStringResource = "Change Bass, Mid or Treble"
    static let isDiscoverable = false
    @Parameter(title: "Region") var region: String
    @Parameter(title: "Step in dB") var step: Double
    init() { region = "bass"; step = 0 }
    init(region: String, step: Double) { self.region = region; self.step = step }
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "tone", arg: region, amount: step)); return .result()
    }
}

struct FlatIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset the Equalizer to Flat"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "flat")); return .result()
    }
}

struct SetPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Choose an Equalizer Preset"
    static let isDiscoverable = false
    @Parameter(title: "Preset") var preset: String
    init() { preset = "" }
    init(preset: String) { self.preset = preset }
    func perform() async throws -> some IntentResult {
        WidgetFiles.send(WidgetCommand(name: "preset", arg: preset)); return .result()
    }
}
