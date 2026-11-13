// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ZuujisCore

final class PlaylistTests: XCTestCase {
    func testAddSkipsDuplicates() {
        var p = Playlist(name: "P")
        XCTAssertEqual(p.add(["a", "b", "a"]), 2)
        XCTAssertEqual(p.add(["b", "c"]), 1)
        XCTAssertEqual(p.paths, ["a", "b", "c"])
    }

    func testRemoveAndMove() {
        var p = Playlist(name: "P", paths: ["a", "b", "c", "d"])
        p.move("d", before: "b")
        XCTAssertEqual(p.paths, ["a", "d", "b", "c"])
        p.move("a", before: nil)
        XCTAssertEqual(p.paths, ["d", "b", "c", "a"])
        p.remove(["b", "zzz"])
        XCTAssertEqual(p.paths, ["d", "c", "a"])
    }

    func testNudgeClampsAtEnds() {
        var p = Playlist(name: "P", paths: ["a", "b", "c"])
        p.nudge("a", by: -1)
        XCTAssertEqual(p.paths, ["a", "b", "c"])
        p.nudge("a", by: 1)
        XCTAssertEqual(p.paths, ["b", "a", "c"])
        p.nudge("c", by: 5)
        XCTAssertEqual(p.paths, ["b", "a", "c"])
    }

    func testUniqueName() {
        let list = [Playlist(name: "Mix"), Playlist(name: "mix 2")]
        XCTAssertEqual(Playlist.uniqueName("Mix", among: list), "Mix 3")
        XCTAssertEqual(Playlist.uniqueName("  ", among: list), "New Playlist")
        XCTAssertEqual(Playlist.uniqueName("Mix", among: list, excluding: list[0].id), "Mix")
    }

    @MainActor
    func testStorePersistsAndEdits() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pl-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PlaylistStore(fileURL: url)
        let a = store.create(name: "A", paths: ["x", "y"])
        XCTAssertEqual(store.create(name: "A").name, "A 2")
        store.rename(a.id, to: "Road")
        XCTAssertEqual(store.add(["y", "z"], to: a.id), 1)
        store.move("z", before: "x", in: a.id)
        store.saveNow()

        let reloaded = PlaylistStore(fileURL: url)
        XCTAssertEqual(reloaded.playlist(a.id)?.name, "Road")
        XCTAssertEqual(reloaded.playlist(a.id)?.paths, ["z", "x", "y"])
        reloaded.delete(a.id)
        XCTAssertNil(reloaded.playlist(a.id))
    }

    func testGenresGroupAndSortNoGenreLast() {
        func t(_ name: String, _ genre: String?) -> LibraryTrack {
            LibraryTrack(url: URL(fileURLWithPath: "/m/\(name).flac"), title: name, genre: genre,
                         size: 1, modified: Date(timeIntervalSince1970: 0))
        }
        let tracks = [t("1", nil), t("2", "Rock"), t("3", "Jazz"), t("4", "Rock")]
        let genres = LibraryModel.genres(tracks)
        XCTAssertEqual(genres.map(\.name), ["Jazz", "Rock", LibraryModel.unknownGenre])
        XCTAssertEqual(genres[1].trackCount, 2)
        XCTAssertEqual(LibraryModel.songs(tracks, inGenre: "Rock").count, 2)
        XCTAssertEqual(LibraryModel.songs(tracks, inGenre: LibraryModel.unknownGenre).count, 1)
        XCTAssertEqual(LibraryModel.songs(tracks, inGenre: nil).count, 4)
    }

    func testGenreSpellingsMerge() {
        func t(_ n: String, _ g: String?) -> LibraryTrack {
            LibraryTrack(url: URL(fileURLWithPath: "/m/\(n).flac"), title: n, genre: g,
                         size: 1, modified: Date(timeIntervalSince1970: 0))
        }
        let tracks = [t("1", "Rock"), t("2", "Rock "), t("3", "rock"), t("4", "Rock"), t("5", "Pop")]
        let genres = LibraryModel.genres(tracks)
        XCTAssertEqual(genres.map(\.name), ["Pop", "Rock"])
        XCTAssertEqual(genres[1].trackCount, 4)
        XCTAssertEqual(LibraryModel.songs(tracks, inGenre: "Rock").count, 4)
    }

    @MainActor
    func testFavoritesPlaylistAlwaysExistsAndToggles() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PlaylistStore(fileURL: url)
        XCTAssertEqual(store.playlists.first?.id, PlaylistStore.favoritesID)
        XCTAssertFalse(store.isFavorite("/m/a.flac"))
        XCTAssertTrue(store.toggleFavorite("/m/a.flac"))
        XCTAssertTrue(store.isFavorite("/m/a.flac"))
        XCTAssertEqual(store.playlist(PlaylistStore.favoritesID)?.paths, ["/m/a.flac"])
        store.rename(PlaylistStore.favoritesID, to: "Nope")
        store.delete(PlaylistStore.favoritesID)
        XCTAssertEqual(store.playlist(PlaylistStore.favoritesID)?.name, "Favorites")
        XCTAssertEqual(store.create(name: "Favorites").name, "Favorites 2")
        XCTAssertFalse(store.toggleFavorite("/m/a.flac"))
        XCTAssertFalse(store.isFavorite("/m/a.flac"))
    }

    func testRelinkFollowsAnUnambiguousMove() {
        var list = Playlist(name: "Mix", paths: ["/old/Band/a.flac", "/old/Band/b.flac", "/old/X/c.flac"])
        let library = ["/new/Band/a.flac", "/new/Band/b.flac", "/n1/X/c.flac", "/n2/X/c.flac"]
        let n = list.relink(missing: Set(list.paths), library: library)
        XCTAssertEqual(n, 2)
        // c.flac matches two library songs, so it is left alone.
        XCTAssertEqual(list.paths, ["/new/Band/a.flac", "/new/Band/b.flac", "/old/X/c.flac"])
    }
}
