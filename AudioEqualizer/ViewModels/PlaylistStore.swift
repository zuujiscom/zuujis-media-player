// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine

/// The user's saved playlists, persisted to Application Support `playlists.json`.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = support.appendingPathComponent("AudioEqualizer", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("playlists.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let saved = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = saved
        }
    }

    func playlist(_ id: UUID?) -> Playlist? {
        guard let id else { return nil }
        return playlists.first { $0.id == id }
    }

    @discardableResult
    func create(name: String, paths: [String] = []) -> Playlist {
        var list = Playlist(name: Playlist.uniqueName(name, among: playlists))
        list.add(paths)
        playlists.append(list)
        changed()
        return list
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = Playlist.uniqueName(name, among: playlists, excluding: id)
        changed()
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        changed()
    }

    /// Adds songs to a playlist. Returns how many were new to it.
    @discardableResult
    func add(_ paths: [String], to id: UUID) -> Int {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        let added = playlists[i].add(paths)
        if added > 0 { changed() }
        return added
    }

    func remove(_ paths: Set<String>, from id: UUID) {
        edit(id) { $0.remove(paths) }
    }

    func move(_ path: String, before target: String?, in id: UUID) {
        edit(id) { $0.move(path, before: target) }
    }

    func nudge(_ path: String, by delta: Int, in id: UUID) {
        edit(id) { $0.nudge(path, by: delta) }
    }

    private func edit(_ id: UUID, _ change: (inout Playlist) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[i])
        changed()
    }

    private func changed() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
