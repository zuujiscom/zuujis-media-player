import XCTest
@testable import AE2Core

@MainActor
final class LibraryStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ae2-lib-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }

    /// A FLAC with only tags: enough for the tag reader, not for playback.
    private func writeFLAC(_ path: String, _ comments: [String]) -> URL {
        var bytes = Array("fLaC".utf8) + [0x00, 0, 0, 34] + [UInt8](repeating: 0, count: 34)
        var block = le32(1) + [0x78] + le32(comments.count)
        for c in comments { let u = Array(c.utf8); block += le32(u.count) + u }
        let len = block.count
        bytes += [0x84, UInt8((len >> 16) & 255), UInt8((len >> 8) & 255), UInt8(len & 255)] + block
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(bytes).write(to: url)
        return url
    }

    private func settle(_ store: LibraryStore) async {
        for _ in 0..<200 where store.isScanning { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    func testScanReadsTagsAndFallsBackToFilenames() async {
        _ = writeFLAC("A/Album/01. One.flac", ["TITLE=One", "ARTIST=Band", "ALBUM=Album", "TRACKNUMBER=1", "DATE=2001"])
        _ = writeFLAC("A/Album/02 - Two.flac", [])           // no tags at all
        FileManager.default.createFile(atPath: root.appendingPathComponent("A/cover.jpg").path, contents: Data())
        let store = LibraryStore(fileURL: root.appendingPathComponent("lib.json"))
        store.addFolders([root.appendingPathComponent("A")])
        await settle(store)

        XCTAssertEqual(store.tracks.count, 2)
        let one = store.tracks.first { $0.title == "One" }
        XCTAssertEqual(one?.artist, "Band")
        XCTAssertEqual(one?.album, "Album")
        XCTAssertEqual(one?.trackNumber, 1)
        XCTAssertEqual(one?.year, 2001)
        let two = store.tracks.first { $0.title == "Two" }
        XCTAssertEqual(two?.trackNumber, 2)
        XCTAssertNil(two?.artist)
    }

    func testPersistsAndRescanKeepsUnchangedTracksAndDropsDeletedOnes() async {
        let a = writeFLAC("M/a.flac", ["TITLE=A", "ARTIST=X"])
        _ = writeFLAC("M/b.flac", ["TITLE=B", "ARTIST=X"])
        let file = root.appendingPathComponent("lib.json")
        let store = LibraryStore(fileURL: file)
        store.addFolders([root.appendingPathComponent("M")])
        await settle(store)
        store.saveNow()

        let reloaded = LibraryStore(fileURL: file)
        XCTAssertEqual(reloaded.tracks.count, 2)          // from disk, before any rescan finishes
        await settle(reloaded)

        try? FileManager.default.removeItem(at: a)
        reloaded.rescan()
        await settle(reloaded)
        XCTAssertEqual(reloaded.tracks.map(\.title), ["B"])
    }

    func testMissingFolderStaysListedAsOffline() async {
        _ = writeFLAC("Drive/x.flac", ["TITLE=X", "ARTIST=Y"])
        let folder = root.appendingPathComponent("Drive")
        let store = LibraryStore(fileURL: root.appendingPathComponent("lib.json"))
        store.addFolders([folder])
        await settle(store)
        XCTAssertEqual(store.tracks.count, 1)

        // "Unplug" the drive.
        let parked = root.appendingPathComponent("Parked")
        try? FileManager.default.moveItem(at: folder, to: parked)
        store.rescan()
        await settle(store)
        XCTAssertEqual(store.tracks.count, 1, "an offline folder keeps its tracks")
        XCTAssertEqual(store.offlineFolders.count, 1)

        // Plug it back in.
        try? FileManager.default.moveItem(at: parked, to: folder)
        store.rescan()
        await settle(store)
        XCTAssertTrue(store.offlineFolders.isEmpty)
        XCTAssertEqual(store.tracks.count, 1)
    }

    func testRemovingAFolderDropsItsTracks() async {
        _ = writeFLAC("P/a.flac", ["TITLE=A"])
        _ = writeFLAC("Q/b.flac", ["TITLE=B"])
        let store = LibraryStore(fileURL: root.appendingPathComponent("lib.json"))
        store.addFolders([root.appendingPathComponent("P"), root.appendingPathComponent("Q")])
        await settle(store)
        XCTAssertEqual(store.tracks.count, 2)
        store.removeFolder(root.appendingPathComponent("P").standardizedFileURL)
        await settle(store)
        XCTAssertEqual(store.tracks.map(\.title), ["B"])
    }

    /// Opt-in: scans a real folder into a throwaway library file and prints
    /// what it found. `AE2_REAL_LIBRARY=/path swift test --filter testRealFolder`.
    func testRealFolder() async throws {
        guard let path = ProcessInfo.processInfo.environment["AE2_REAL_LIBRARY"] else { throw XCTSkip("AE2_REAL_LIBRARY not set") }
        let store = LibraryStore(fileURL: root.appendingPathComponent("lib.json"))
        store.addFolders([URL(fileURLWithPath: path)])
        for _ in 0..<2400 where store.isScanning { try? await Task.sleep(nanoseconds: 100_000_000) }
        let artists = LibraryModel.artists(store.tracks)
        print("REAL: \(store.tracks.count) tracks, \(artists.count) artists, \(LibraryModel.albums(store.tracks, artist: nil).count) albums")
        for a in artists.prefix(12) { print("REAL artist: \(a.name) (\(a.trackCount))") }
        print("REAL unknown-artist tracks: \(store.tracks.filter { $0.artist == nil }.count)")
        print("REAL no-duration: \(store.tracks.filter { $0.duration == nil }.count)")
    }
}
