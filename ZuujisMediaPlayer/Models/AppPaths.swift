// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where the app keeps its files: `~/Library/Application Support/Zuujis Media Player/`.
enum AppPaths {
    static let folderName = "Zuujis Media Player"
    /// The app was called AudioEqualizer (bundle `com.zuujis.AudioEqualizer`)
    /// before the rename; its data is moved over once on first launch.
    static let oldFolderName = "AudioEqualizer"
    static let oldBundleID = "com.zuujis.AudioEqualizer"

    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent(folderName, isDirectory: true)
        #if DEBUG
        // Screenshots and experiments run against a throwaway folder.
        if let custom = ProcessInfo.processInfo.environment["ZUUJIS_DATA_DIR"] {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        }
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Moves the old Application Support folder and preferences to the new
    /// names when the new ones do not exist yet. Must run before any store
    /// reads its file.
    static func migrateFromOldName() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZUUJIS_DATA_DIR"] != nil { return }
        #endif
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent(oldFolderName, isDirectory: true)
        let new = base.appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }
        // Old preferences fill in what the new domain lacks, once.
        let defaults = UserDefaults.standard
        let marker = "migratedFromAudioEqualizer"
        if let id = Bundle.main.bundleIdentifier, id != oldBundleID, !defaults.bool(forKey: marker) {
            let saved = defaults.persistentDomain(forName: oldBundleID) ?? [:]
            var current = defaults.persistentDomain(forName: id) ?? [:]
            for (key, value) in saved where current[key] == nil { current[key] = value }
            current[marker] = true
            defaults.setPersistentDomain(current, forName: id)
        }
    }
}
