import XCTest
@testable import DropNestCore

final class ArchiveTests: XCTestCase {
    var base: URL!
    var root: URL { base.appendingPathComponent("Archive") }
    var ledger: URL { base.appendingPathComponent("State/history.json") }
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNestTests-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    func file(_ name: String, text: String = "sample") throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data(text.utf8).write(to: url); return url
    }
    func decision(_ path: String = "文档") -> Decision { Decision(folder: path, reason: "test") }

    func testMovePersistReloadAndUndo() throws {
        let source = try file("report.pdf")
        let journal = try ArchiveJournal(file: ledger)
        let record = try journal.archive(source: source, root: root, decision: decision())
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOfFile: record.destination, encoding: .utf8), "sample")
        let reloaded = try ArchiveJournal(file: ledger)
        try reloaded.undo(id: record.id)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "sample")
        XCTAssertEqual(try ArchiveJournal(file: ledger).records.first?.status, .undone)
    }
    func testCollisionKeepsBothFiles() throws {
        let journal = try ArchiveJournal(file: ledger)
        let source = try file("report.pdf", text: "first")
        let first = try journal.archive(source: source, root: root, decision: decision())
        _ = try file("report.pdf", text: "second")
        let second = try journal.archive(source: source, root: root, decision: decision())
        XCTAssertTrue(second.destination.hasSuffix("report (2).pdf"))
        XCTAssertEqual(try String(contentsOfFile: first.destination, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOfFile: second.destination, encoding: .utf8), "second")
    }
    func testUndoNeverOverwritesSource() throws {
        let journal = try ArchiveJournal(file: ledger)
        let source = try file("notes.txt")
        let record = try journal.archive(source: source, root: root, decision: decision())
        _ = try file("notes.txt", text: "new file")
        XCTAssertThrowsError(try journal.undo(id: record.id))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.destination))
    }
    func testUndoRejectsChangedArchive() throws {
        let journal = try ArchiveJournal(file: ledger)
        let record = try journal.archive(source: file("notes.txt"), root: root, decision: decision())
        try Data("changed file with different size".utf8).write(to: URL(fileURLWithPath: record.destination))
        XCTAssertThrowsError(try journal.undo(id: record.id))
    }
    func testFolderMovesAsAUnit() throws {
        let source = base.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: source.appendingPathComponent("a.txt"))
        let journal = try ArchiveJournal(file: ledger)
        let record = try journal.archive(source: source, root: root, decision: decision("文件夹"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.destination + "/a.txt"))
        try journal.undo(id: record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.txt").path))
    }
    func testAlreadyArchivedAndAncestorAreRejected() throws {
        let journal = try ArchiveJournal(file: ledger)
        let record = try journal.archive(source: file("a.txt"), root: root, decision: decision())
        XCTAssertThrowsError(try journal.archive(source: URL(fileURLWithPath: record.destination), root: root, decision: decision()))
        XCTAssertThrowsError(try journal.archive(source: base, root: root, decision: decision()))
    }
    func testPathTraversalRejectedBeforeMove() throws {
        let source = try file("a.txt")
        let journal = try ArchiveJournal(file: ledger)
        for path in ["../escape", "/tmp/escape", "a/../../b", "a//b", ".hidden", "a\\b", "a\n"] {
            XCTAssertThrowsError(try journal.archive(source: source, root: root, decision: decision(path)), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testSymlinkDestinationEscapeRejected() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let source = try file("a.txt")
        let journal = try ArchiveJournal(file: ledger)
        XCTAssertThrowsError(try journal.archive(source: source, root: root, decision: decision("link/subfolder")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("subfolder").path))
    }
    func testSourceSymlinkRejected() throws {
        let real = try file("a.txt")
        let link = base.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let journal = try ArchiveJournal(file: ledger)
        XCTAssertThrowsError(try journal.archive(source: link, root: root, decision: decision()))
    }
    func testInterruptedMoveRequiresReview() throws {
        let source = try file("a.txt")
        let journal = try ArchiveJournal(file: ledger)
        let record = try journal.archive(source: source, root: root, decision: decision())
        var interrupted = record; interrupted.status = .planned; interrupted.stamp = nil
        try JSONEncoder().encode([interrupted]).write(to: ledger)
        let recovered = try ArchiveJournal(file: ledger)
        XCTAssertEqual(recovered.records.first?.status, .needsReview)
        XCTAssertThrowsError(try recovered.undo(id: record.id))
    }
    func testCorruptHistoryDoesNotGetOverwritten() throws {
        try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: ledger)
        XCTAssertThrowsError(try ArchiveJournal(file: ledger))
        XCTAssertEqual(try String(contentsOf: ledger, encoding: .utf8), "corrupt")
    }
    func testFirstMatchingEnabledRuleWins() {
        let url = URL(fileURLWithPath: "/tmp/Customer-contract.PDF")
        let rules = [SortRule(keyword: "customer", folder: "skip", enabled: false),
                     SortRule(keyword: "CUSTOMER", folder: "工作/客户"),
                     SortRule(keyword: "contract", folder: "工作/合同")]
        XCTAssertEqual(RuleEngine.customDecision(for: url, rules: rules)?.folder, "工作/客户")
    }
    func testUnknownFileGoesToPending() {
        XCTAssertEqual(RuleEngine.fallback(for: URL(fileURLWithPath: "/a/unrecognized.foo"), isDirectory: false).folder, "待整理")
        XCTAssertEqual(RuleEngine.fallback(for: URL(fileURLWithPath: "/a/PIC.PNG"), isDirectory: false).folder, "图片")
    }
    func testExistingConfigMigratesWithoutEnablingUploads() throws {
        let data = Data(#"{"useAI":true,"floating":true,"rules":[]}"#.utf8)
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(config.aiProvider, .compatible)
        XCTAssertFalse(config.allowContentUpload)
    }
    func testAPIRejectsCredentialsInURLAndInsecureRemoteTransport() {
        XCTAssertNil(CompatibleAPI.endpoint("http://example.com/v1/chat/completions"))
        XCTAssertNil(CompatibleAPI.endpoint("https://secret@example.com/v1/chat/completions"))
        XCTAssertNil(CompatibleAPI.endpoint("https://example.com/v1/chat/completions?key=secret"))
        XCTAssertNotNil(CompatibleAPI.endpoint("http://127.0.0.1:11434/v1/chat/completions"))
        XCTAssertNotNil(CompatibleAPI.endpoint("https://api.deepseek.com/chat/completions"))
    }
    func testAPIResultCannotSupplyAnArbitraryPath() {
        XCTAssertThrowsError(try CompatibleAPI.decodeDecision(Data(#"{"category":"../../outside","confident":true}"#.utf8)))
        XCTAssertThrowsError(try CompatibleAPI.decodeDecision(Data(#"{"category":"receipts","confident":"yes"}"#.utf8)))
    }
    func testUncertainAIResultGoesToPending() throws {
        let decision = try CompatibleAPI.decodeDecision(Data(#"{"category":"contracts","confident":false}"#.utf8))
        XCTAssertEqual(decision.folder, "待整理")
    }
    func testCertainAIResultMapsToFixedCategory() throws {
        let decision = try CompatibleAPI.decodeDecision(Data(#"{"category":"receipts","confident":true}"#.utf8))
        XCTAssertEqual(decision.folder, "工作/票据")
    }
}
