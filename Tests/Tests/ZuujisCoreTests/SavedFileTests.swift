import XCTest
@testable import ZuujisCore

final class SavedFileTests: XCTestCase {
    var dir: URL!
    var file: URL { dir.appendingPathComponent("data.json") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testMissingFileLoadsNil() {
        XCTAssertNil(SavedFile.load([Int].self, from: file, label: "t"))
    }

    func testSaveKeepsPreviousAsBackup() throws {
        XCTAssertTrue(SavedFile.save([1], to: file, label: "t"))
        XCTAssertTrue(SavedFile.save([2], to: file, label: "t"))
        XCTAssertEqual(SavedFile.load([Int].self, from: file, label: "t"), [2])
        let bak = try Data(contentsOf: SavedFile.backupURL(for: file))
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: bak), [1])
    }

    func testCorruptFileIsMovedAsideAndBackupRestored() throws {
        SavedFile.save([1], to: file, label: "t")
        SavedFile.save([2], to: file, label: "t")
        try Data("garbage".utf8).write(to: file)
        XCTAssertEqual(SavedFile.load([Int].self, from: file, label: "t"), [1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("data.corrupt-") })
    }

    func testCorruptFileWithoutBackupIsKeptNotOverwritten() throws {
        try Data("garbage".utf8).write(to: file)
        XCTAssertNil(SavedFile.load([Int].self, from: file, label: "t"))
        SavedFile.save([3], to: file, label: "t")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let corrupt = try XCTUnwrap(names.first { $0.hasPrefix("data.corrupt-") })
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(corrupt)), "garbage")
    }

    func testFailedSaveReturnsFalse() {
        let bad = dir.appendingPathComponent("no/such/dir/x.json")
        XCTAssertFalse(SavedFile.save([1], to: bad, label: "t"))
    }
}
