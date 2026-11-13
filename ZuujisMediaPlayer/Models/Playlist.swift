// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A saved, named list of songs. Songs are kept as file paths, so a playlist
/// survives a rescan and a song whose drive is unplugged keeps its place.
struct Playlist: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var paths: [String] = []
    var created = Date()

    /// Appends `new` in order, skipping songs already in the playlist (and
    /// repeats within `new`). Returns how many were added.
    @discardableResult
    mutating func add(_ new: [String]) -> Int {
        var seen = Set(paths)
        var added = 0
        for path in new where seen.insert(path).inserted {
            paths.append(path)
            added += 1
        }
        return added
    }

    mutating func remove(_ doomed: Set<String>) {
        paths.removeAll { doomed.contains($0) }
    }

    /// Moves `path` so it sits just before `target` (or last when `target` is nil).
    mutating func move(_ path: String, before target: String?) {
        guard path != target, let from = paths.firstIndex(of: path) else { return }
        paths.remove(at: from)
        if let target, let to = paths.firstIndex(of: target) {
            paths.insert(path, at: to)
        } else {
            paths.append(path)
        }
    }

    /// Moves `path` one place up or down.
    mutating func nudge(_ path: String, by delta: Int) {
        guard let from = paths.firstIndex(of: path) else { return }
        let to = min(max(from + delta, 0), paths.count - 1)
        guard to != from else { return }
        paths.remove(at: from)
        paths.insert(path, at: to)
    }

    /// A name no other playlist uses: "Mix", then "Mix 2", "Mix 3"…
    static func uniqueName(_ wanted: String, among existing: [Playlist], excluding: UUID? = nil) -> String {
        let base = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = base.isEmpty ? "New Playlist" : base
        let taken = Set(existing.filter { $0.id != excluding }.map { $0.name.lowercased() })
        guard taken.contains(root.lowercased()) else { return root }
        var n = 2
        while taken.contains("\(root) \(n)".lowercased()) { n += 1 }
        return "\(root) \(n)"
    }

    /// Points songs whose file has gone at the library's copy when the move
    /// is unambiguous: exactly one library song has the same file name and
    /// folder name (artist/album folders usually survive a move). Returns
    /// how many were relinked.
    @discardableResult
    mutating func relink(missing: Set<String>, library: [String]) -> Int {
        func key(_ path: String) -> String {
            let parts = path.split(separator: "/").suffix(2)
            return parts.joined(separator: "/").lowercased()
        }
        let present = Set(paths)
        var byKey: [String: [String]] = [:]
        for path in library where !present.contains(path) { byKey[key(path), default: []].append(path) }
        var used = Set<String>()
        var count = 0
        for i in paths.indices where missing.contains(paths[i]) {
            guard let found = byKey[key(paths[i])], found.count == 1,
                  let new = found.first, used.insert(new).inserted else { continue }
            paths[i] = new
            count += 1
        }
        return count
    }
}
