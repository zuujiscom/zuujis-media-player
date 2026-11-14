// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine

/// Reads and writes the app's JSON files without losing data quietly.
///
/// - Every save first copies the current file to `<name>.bak`, so the last good
///   save survives a bad one.
/// - A file that exists but cannot be read is moved aside to
///   `<name>.corrupt-<date>.json` before anything can overwrite it, and the
///   backup is used instead when it reads.
/// - Any of this, and any failed save, is reported through `DataIssues`.
enum SavedFile {
    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("bak")
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL, label: String) -> T? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // No main file: a backup alone means the last write went missing.
            return restoreBackup(type, for: url, label: label, reason: "was missing")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let moved = quarantine(url)
            let where_ = moved.map { " A copy was kept as \($0.lastPathComponent)." } ?? ""
            if let restored = restoreBackup(type, for: url, label: label, reason: "could not be read") {
                return restored
            }
            DataIssues.report("Your \(label) could not be read and started empty.\(where_)")
            return nil
        }
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL, label: String, encoder: JSONEncoder = JSONEncoder()) -> Bool {
        let fm = FileManager.default
        do {
            let data = try encoder.encode(value)
            if fm.fileExists(atPath: url.path) {
                let bak = backupURL(for: url)
                try? fm.removeItem(at: bak)
                try? fm.copyItem(at: url, to: bak)
            }
            try data.write(to: url, options: .atomic)
            DataIssues.clear(label)
            return true
        } catch {
            DataIssues.report("Your \(label) could not be saved: \(error.localizedDescription)", key: label)
            return false
        }
    }

    private static func restoreBackup<T: Decodable>(_ type: T.Type, for url: URL, label: String, reason: String) -> T? {
        let bak = backupURL(for: url)
        guard let data = try? Data(contentsOf: bak),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        DataIssues.report("Your \(label) file \(reason), so the previous save was restored.")
        return value
    }

    /// Moves an unreadable file aside so the next save cannot overwrite it.
    private static func quarantine(_ url: URL) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = url.deletingPathExtension().lastPathComponent
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(f.string(from: Date())).\(url.pathExtension)")
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}

/// Problems with saved data, shown in the main window until dismissed.
final class DataIssues: ObservableObject {
    static let shared = DataIssues()

    @Published private(set) var message: String?
    /// Which save is failing, so a later good save of the same file clears it.
    private var key: String?

    static func report(_ message: String, key: String? = nil) {
        NSLog("Zuujis data: %@", message)
        onMain {
            shared.message = message
            shared.key = key
        }
    }

    static func clear(_ key: String) {
        onMain {
            if shared.key == key { shared.message = nil; shared.key = nil }
        }
    }

    func dismiss() { message = nil; key = nil }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
