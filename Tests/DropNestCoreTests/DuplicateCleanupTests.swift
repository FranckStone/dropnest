import XCTest
@testable import DropNestCore

final class DuplicateCleanupTests: XCTestCase {
    private var base: URL!
    private var root: URL { base.appendingPathComponent("archive") }
    private var trash: URL { base.appendingPathComponent("test-trash") }
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    @discardableResult private func write(_ path: String, _ contents: String = "identical") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
    private func moveToTestTrash(_ url: URL) throws -> URL {
        let target = trash.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
    func testEachGroupKeepsFirstAndMovesOnlyItsOtherCopies() throws {
        let keptA = try write("a.txt")
        let b = try write("nested/b.txt")
        let c = try write("nested/c.txt")
        let keptD = try write("d.txt", "another content")
        let e = try write("e.txt", "another content")
        let unique = try write("unique.txt", "only one")
        let groups = try DuplicateFiles.groups(root: root)
        let result = DuplicateCleanup.clean(groups: groups, root: root, trash: moveToTestTrash)
        XCTAssertEqual(result.trashed.count, 3)
        XCTAssertTrue(result.issues.isEmpty)
        for url in [keptA, keptD, unique] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        for url in [b, c, e] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        for record in result.trashed {
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.trashPath))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: record.trashPath)),
                           try Data(contentsOf: URL(fileURLWithPath: record.keptPath)))
        }
        XCTAssertTrue(try DuplicateFiles.groups(root: root).isEmpty)
    }
    func testChangedKeeperLeavesEveryCopyAlone() throws {
        let keeper = try write("a.txt")
        let copy = try write("b.txt")
        let groups = try DuplicateFiles.groups(root: root)
        try Data("changed".utf8).write(to: keeper)
        let result = DuplicateCleanup.clean(groups: groups, root: root, trash: moveToTestTrash)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }
    func testChangedCopyIsSkippedWhileUnchangedCopyCanBeTrashed() throws {
        let keeper = try write("a.txt")
        let changed = try write("b.txt")
        _ = try write("c.txt")
        let groups = try DuplicateFiles.groups(root: root)
        try Data("changed".utf8).write(to: changed)
        let result = DuplicateCleanup.clean(groups: groups, root: root, trash: moveToTestTrash)
        XCTAssertEqual(result.trashed.count, 1)
        XCTAssertEqual(result.issues.map(\.path), ["b.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
        XCTAssertEqual(try String(contentsOf: changed, encoding: .utf8), "changed")
    }
    func testMissingKeeperDuringCleanupProtectsRemainingCopy() throws {
        let keeper = try write("a.txt")
        _ = try write("b.txt")
        let remaining = try write("c.txt")
        let groups = try DuplicateFiles.groups(root: root)
        let result = DuplicateCleanup.clean(groups: groups, root: root, trash: { url in
            let target = try self.moveToTestTrash(url)
            try FileManager.default.moveItem(at: keeper, to: self.base.appendingPathComponent("keeper-moved-away"))
            return target
        })
        XCTAssertEqual(result.trashed.count, 1)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remaining.path))
    }
    func testTrashFailurePreservesFilesAndReportsIssue() throws {
        let keeper = try write("a.txt")
        let copy = try write("b.txt")
        let groups = try DuplicateFiles.groups(root: root)
        let result = DuplicateCleanup.clean(groups: groups, root: root, trash: { _ in
            throw ArchiveError.invalid("Trash unavailable")
        })
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }
    func testReplacementWithSameBytesAndModificationDateIsNotTrashed() throws {
        _ = try write("a.txt")
        let copy = try write("b.txt")
        let groups = try DuplicateFiles.groups(root: root)
        let date = try FileStamp.read(copy).modified
        try FileManager.default.moveItem(at: copy, to: base.appendingPathComponent("original-b.txt"))
        try Data("identical".utf8).write(to: copy)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copy.path)
        let result = DuplicateCleanup.clean(groups: groups, root: root, trash: moveToTestTrash)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }
    func testParentReplacedBySymlinkDoesNotTrashExternalFile() throws {
        _ = try write("a.txt")
        _ = try write("nested/b.txt")
        let groups = try DuplicateFiles.groups(root: root)
        let nested = root.appendingPathComponent("nested")
        let external = base.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: nested, to: external)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: external)
        let result = DuplicateCleanup.clean(groups: groups, root: root, trash: moveToTestTrash)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("b.txt").path))
    }
    func testSystemTrashMovesAndCanRestoreOnlyGeneratedTestFile() throws {
        let generated = try write("trash-integration-\(UUID()).txt", "temporary test data")
        let target = try DuplicateCleanup.systemTrash(generated)
        // Restore this test's own file; no existing user Trash item is touched.
        defer {
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: target, to: generated)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: generated.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "temporary test data")
    }
}
