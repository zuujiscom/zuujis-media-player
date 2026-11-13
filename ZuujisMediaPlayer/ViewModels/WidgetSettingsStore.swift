// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation

/// The desktop widgets' settings, kept in the app's preferences. Settings
/// edits them; `WidgetBridge` watches them and hands each change to the
/// widgets with the rest of their state.
@MainActor
final class WidgetSettingsStore: ObservableObject {
    static let key = "widgetSettings"

    @Published var settings: WidgetSettings {
        didSet {
            guard settings != oldValue, let data = try? JSONEncoder().encode(settings) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    init() {
        settings = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(WidgetSettings.self, from: $0) } ?? WidgetSettings()
    }

    func reset() { settings = WidgetSettings() }

    // MARK: The Equalizer widget's presets

    /// Puts `name` on the widget, or takes it off. Starting from "all of
    /// them", the first change makes the list explicit.
    func togglePreset(_ name: String, all: [String]) {
        var list = settings.offeredPresets(from: all)
        if let index = list.firstIndex(of: name) { list.remove(at: index) } else { list.append(name) }
        settings.eqPresets = list
    }

    func movePreset(_ name: String, by delta: Int, all: [String]) {
        var list = settings.offeredPresets(from: all)
        guard let from = list.firstIndex(of: name), list.indices.contains(from + delta) else { return }
        list.swapAt(from, from + delta)
        settings.eqPresets = list
    }
}
