import XCTest
@testable import ZuujisCore

@MainActor
final class PlaybackQueueTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zuujis-queue-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func makeFiles(_ names: [String]) -> [URL] {
        names.map { name in
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return url
        }
    }

    /// A queue over `a b c`, with `a` current. Persists into the temp folder,
    /// never the user's Application Support.
    private func queue(_ names: [String] = ["a.flac", "b.flac", "c.flac"]) -> PlaybackQueue {
        let q = PlaybackQueue(fileURL: dir.appendingPathComponent("queue.json"))
        let items = q.add(urls: makeFiles(names))
        q.setCurrent(items.first?.id)
        return q
    }

    func testOnlyAudioFilesAreAdded() {
        let q = PlaybackQueue(fileURL: dir.appendingPathComponent("queue.json"))
        let added = q.add(urls: makeFiles(["a.flac", "notes.txt", "b.MP3", "cover.jpg"]))
        XCTAssertEqual(Set(added.map { $0.url.lastPathComponent }), ["a.flac", "b.MP3"])
    }

    func testPlaysInListOrderAndEnds() {
        let q = queue()
        XCTAssertEqual(q.itemAfterCurrent()?.title, "b")
        q.setCurrent(q.items[2].id)
        XCTAssertNil(q.itemAfterCurrent())
        XCTAssertNil(q.itemForSkipForward())
    }

    func testRepeatAllWrapsBothWays() {
        let q = queue()
        q.repeatMode = .all
        XCTAssertEqual(q.itemForSkipBack()?.title, "c")
        q.setCurrent(q.items[2].id)
        XCTAssertEqual(q.itemAfterCurrent()?.title, "a")
        XCTAssertEqual(q.itemForSkipForward()?.title, "a")
    }

    func testRepeatOneRepeatsOnItsOwnButDoesNotTrapNext() {
        let q = queue()
        q.repeatMode = .one
        XCTAssertEqual(q.itemAfterCurrent()?.title, "a")
        XCTAssertEqual(q.itemForSkipForward()?.title, "b")
    }

    func testPreviousAtTheStartStopsWhenNotRepeating() {
        XCTAssertNil(queue().itemForSkipBack())
    }

    func testShuffleVisitsEveryItemOnceStartingWithTheCurrent() {
        let q = queue(["a.flac", "b.flac", "c.flac", "d.flac", "e.flac"])
        q.shuffle = true
        var seen = [q.current!.title]
        while let next = q.itemAfterCurrent() {
            q.setCurrent(next.id)
            seen.append(next.title)
        }
        XCTAssertEqual(seen.first, "a")
        XCTAssertEqual(Set(seen), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(seen.count, 5)
    }

    func testSurvivesARelaunch() {
        let q = queue()
        q.repeatMode = .all
        q.setCurrent(q.items[1].id)
        q.saveNow()

        let reloaded = PlaybackQueue(fileURL: q.fileURL)
        XCTAssertEqual(reloaded.items.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(reloaded.current?.title, "b")
        XCTAssertEqual(reloaded.repeatMode, .all)
    }
}
