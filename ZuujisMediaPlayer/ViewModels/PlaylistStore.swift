// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine

/// The user's saved playlists, persisted to Application Support `playlists.json`.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    /// Paths in Favorites, for fast heart lookups.
    @Published private(set) var favoritePaths: Set<String> = []

    /// Favorites is an ordinary playlist with a fixed id: it always exists,
    /// sorts first, and cannot be renamed or deleted.
    static let favoritesID = UUID(uuidString: "FA0E17E5-0000-4000-8000-00000000F4B5")!
    let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppPaths.support.appendingPathComponent("playlists.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let saved = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = saved
        }
        if !playlists.contains(where: { $0.id == Self.favoritesID }) {
            playlists.insert(Playlist(id: Self.favoritesID, name: "Favorites"), at: 0)
        }
        refreshFavorites()
    }

    func isFavorite(_ path: String) -> Bool { favoritePaths.contains(path) }

    /// Hearts or un-hearts a song. Returns the new state.
    @discardableResult
    func toggleFavorite(_ path: String) -> Bool {
        if favoritePaths.contains(path) {
            remove([path], from: Self.favoritesID)
            return false
        }
        add([path], to: Self.favoritesID)
        return true
    }

    private func refreshFavorites() {
        favoritePaths = Set(playlist(Self.favoritesID)?.paths ?? [])
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
        guard id != Self.favoritesID, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = Playlist.uniqueName(name, among: playlists, excluding: id)
        changed()
    }

    func delete(_ id: UUID) {
        guard id != Self.favoritesID else { return }
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

    /// After a library scan: playlists whose songs moved follow them.
    /// `exists` is asked only about paths the library does not know.
    func relink(library: [String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        let known = Set(library)
        var changedAny = false
        for i in playlists.indices {
            let missing = Set(playlists[i].paths.filter { !known.contains($0) && !exists($0) })
            guard !missing.isEmpty else { continue }
            if playlists[i].relink(missing: missing, library: library) > 0 { changedAny = true }
        }
        if changedAny { changed() }
    }

    private func edit(_ id: UUID, _ change: (inout Playlist) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[i])
        changed()
    }

    private func changed() {
        refreshFavorites()
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
