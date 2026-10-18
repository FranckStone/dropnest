import XCTest
@testable import DropNestCore

final class DuplicateTests: XCTestCase {
    private var base: URL!
    private var root: URL { base.appendingPathComponent("archive") }
    private var ledger: URL { base.appendingPathComponent("state/history.json") }
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Duplicates-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func write(_ relative: String, data: Data) throws -> URL {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    func testRenamedDuplicateIsRecordedWithoutMovingOrCreatingFolders() throws {
        let data = Data(repeating: 42, count: 200_003)
        let archived = try write("archive/旧目录/原件.bin", data: data)
        let source = try write("改名后的副本.txt", data: data)
        let journal = try ArchiveJournal(file: ledger)
        let record = try journal.archive(source: source, root: root, decision: Decision(folder: "新目录", reason: "test"))
        XCTAssertEqual(record.status, .duplicate)
        XCTAssertEqual(record.destination, archived.path)
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("新目录").path))
        XCTAssertEqual(try ArchiveJournal(file: ledger).records.first?.status, .duplicate)
        XCTAssertThrowsError(try journal.undo(id: record.id))
    }
    func testSameSizeAndNameWithDifferentLastByteIsArchived() throws {
        var data = Data(repeating: 42, count: 200_003)
        let original = try write("archive/文档/a.bin", data: data)
        data[data.count - 1] = 43
        let source = try write("a.bin", data: data)
        let journal = try ArchiveJournal(file: ledger)
        let record = try journal.archive(source: source, root: root, decision: Decision(folder: "文档", reason: "test"))
        XCTAssertEqual(record.status, .moved)
        XCTAssertTrue(record.destination.hasSuffix("a (2).bin"))
        XCTAssertNotEqual(try Data(contentsOf: original), try Data(contentsOf: URL(fileURLWithPath: record.destination)))
    }
    func testNewlyArchivedFilesAreSeenByLaterItemsAndUndoWorks() throws {
        let first = try write("a.txt", data: Data("same contents".utf8))
        let second = try write("b.txt", data: Data("same contents".utf8))
        let journal = try ArchiveJournal(file: ledger)
        let moved = try journal.archive(source: first, root: root, decision: Decision(folder: "文档", reason: "test"))
        let skipped = try journal.archive(source: second, root: root, decision: Decision(folder: "另一个目录", reason: "test"))
        XCTAssertEqual(skipped.status, .duplicate)
        try journal.undo(id: moved.id)
        XCTAssertNil(try DuplicateFiles.match(source: second, root: root))
    }
    func testGroupsHandleEmptyFilesAndIgnoreLinksAndPackages() throws {
        _ = try write("archive/甲.txt", data: Data())
        _ = try write("archive/子目录/乙.txt", data: Data())
        _ = try write("archive/不同.txt", data: Data("x".utf8))
        let outside = try write("外部.txt", data: Data())
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("链接.txt"), withDestinationURL: outside)
        _ = try write("archive/Ignore.app/inside.txt", data: Data())
        _ = try write("archive/node_modules/ignore.txt", data: Data())
        _ = try write("archive/.hidden.txt", data: Data())
        let groups = try DuplicateFiles.groups(root: root)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].documents.map(\.path)), ["甲.txt", "子目录/乙.txt"])
    }
    func testParallelHashingAcrossBatchesKeepsGroupsAndCollisionsApart() throws {
        // 90 same-size files span three hash batches: 30 copies each of three
        // contents, plus same-size files whose bytes differ.
        for index in 0..<90 {
            _ = try write("archive/组\(index % 3)/\(index).bin", data: Data(repeating: UInt8(index % 3), count: 4096))
        }
        for index in 0..<5 {
            var bytes = Data(repeating: 9, count: 4096); bytes[4095] = UInt8(index)
            _ = try write("archive/单独/\(index).bin", data: bytes)
        }
        var reported: [(Int, Int)] = []
        let lock = NSLock()
        let groups = try DuplicateFiles.groups(root: root) { current, total in lock.lock(); reported.append((current, total)); lock.unlock() }
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.documents.count), [30, 30, 30])
        for group in groups { XCTAssertEqual(Set(group.documents.map { $0.path.split(separator: "/")[0] }).count, 1) }
        XCTAssertEqual(reported.last?.0, 95); XCTAssertEqual(reported.last?.1, 95)
    }
    func testPendingCheckExcludesItselfButFindsAnotherCopy() throws {
        let source = try write("archive/待整理/a.txt", data: Data("same".utf8))
        XCTAssertNil(try DuplicateFiles.match(source: source, root: root))
        let copy = try write("archive/工作/a-copy.txt", data: Data("same".utf8))
        let journal = try ArchiveJournal(file: ledger)
        let record = try journal.archivePending(source: source, root: root, decision: Decision(folder: "工作", reason: "test"))
        XCTAssertEqual(record.status, .duplicate)
        XCTAssertEqual(record.destination, copy.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testUnreadableCandidateStopsArchiveAndPreservesSource() throws {
        let existing = try write("archive/不可读.txt", data: Data("same".utf8))
        let source = try write("副本.txt", data: Data("same".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: existing.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: existing.path) }
        let journal = try ArchiveJournal(file: ledger)
        XCTAssertThrowsError(try journal.archive(source: source, root: root, decision: Decision(folder: "新目录", reason: "test")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(journal.records.isEmpty)
    }
}
