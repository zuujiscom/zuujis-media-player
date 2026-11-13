// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ServiceManagement

/// The "Open at Login" switch, backed by `SMAppService`. The app is a login
/// item so its menu bar controls are always there; it starts hidden (see
/// `AppDelegate`) and the system lists it under Login Items in System Settings.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled = false
    /// macOS wants the user to approve it in System Settings.
    @Published private(set) var needsApproval = false

    private static let configuredKey = "launchAtLoginConfigured"

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Open at Login: \(error.localizedDescription)")
        }
        refresh()
    }

    /// The first time an *installed* copy runs, turn the login item on, once.
    /// A build in DerivedData or a download folder never registers itself, and
    /// turning it off afterwards sticks: this only ever runs once.
    func enableOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: Self.configuredKey) else { return }
        let path = Bundle.main.bundleURL.path
        let home = NSHomeDirectory()
        guard path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: Self.configuredKey)
        if !isEnabled { set(true) }
    }
}
