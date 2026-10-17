import XCTest
@testable import DropNestCore

final class InvoiceImportTests: XCTestCase {
    private var base: URL!
    private var root: URL { base.appendingPathComponent("archive") }
    private var source: URL { base.appendingPathComponent("10月差旅") }
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Invoice-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    @discardableResult private func write(_ relative: String, under parent: URL, text: String = "虚构测试发票") throws -> URL {
        let url = parent.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func context(purpose: String = "出差报销") throws -> InvoiceContext {
        try InvoiceContext(sourceFolder: source, relativeFolder: "上海/酒店", purpose: purpose, categories: ["交通", "住宿", "餐饮"])
    }
    func testScanPreservesSourceSubfoldersAndSkipsUnsupportedAndLinks() throws {
        let pdf = try write("上海/酒店/001.pdf", under: source)
        _ = try write("车票/002.png", under: source)
        _ = try write("archive.zip", under: source)
        _ = try write("invoice.ofd", under: source)
        _ = try write(".hidden.pdf", under: source)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.pdf"), withDestinationURL: pdf)
        let batch = try InvoiceBatch.scan(folder: source, archiveRoot: root)
        XCTAssertEqual(batch.items.count, 2)
        XCTAssertEqual(batch.items.first(where: { $0.url == pdf })?.relativeFolder, "上海/酒店")
        XCTAssertEqual(batch.unsupportedCount, 2)
        XCTAssertThrowsError(try InvoiceBatch.scan(folder: root, archiveRoot: root))
        XCTAssertThrowsError(try InvoiceBatch.scan(folder: base, archiveRoot: root))
    }
    func testExplicitPurposeWinsAndCategoryIsBoundToAllowedID() throws {
        let reply = Data(#"{"is_invoice":true,"purpose":"../../escape","purpose_confident":true,"category_id":1,"confident":true,"reason":"住宿费"}"#.utf8)
        let decision = try XCTUnwrap(InvoiceRouting.decode(reply, context: context()))
        XCTAssertEqual(decision.folder, "10月差旅/出差报销/住宿")
        XCTAssertFalse(decision.requiresExistingFolder)
    }
    func testAmbiguousPurposeAndTypeAreExplicitlyMarked() throws {
        let reply = Data(#"{"is_invoice":true,"purpose":"猜测的用途","purpose_confident":false,"category_id":-1,"confident":false,"reason":"线索不足"}"#.utf8)
        XCTAssertEqual(try InvoiceRouting.decode(reply, context: context(purpose: ""))?.folder, "10月差旅/用途待确认/分类待确认")
        let nonInvoice = Data(#"{"is_invoice":false,"purpose":"","purpose_confident":false,"category_id":-1,"confident":false,"reason":"合同"}"#.utf8)
        XCTAssertNil(try InvoiceRouting.decode(nonInvoice, context: context()))
    }
    func testInvalidTypesAndPurposePathsAreRejected() throws {
        let badID = Data(#"{"is_invoice":true,"purpose":"差旅","purpose_confident":true,"category_id":99,"confident":true,"reason":"test"}"#.utf8)
        XCTAssertThrowsError(try InvoiceRouting.decode(badID, context: context()))
        let badPurpose = Data(#"{"is_invoice":true,"purpose":"../outside","purpose_confident":true,"category_id":0,"confident":true,"reason":"test"}"#.utf8)
        XCTAssertThrowsError(try InvoiceRouting.decode(badPurpose, context: context(purpose: "")))
        XCTAssertThrowsError(try InvoiceContext(sourceFolder: source, relativeFolder: "", purpose: "a/b", categories: ["交通"]))
        XCTAssertThrowsError(try InvoiceContext(sourceFolder: source, relativeFolder: "", purpose: "", categories: ["../escape"]))
        XCTAssertThrowsError(try InvoiceContext(sourceFolder: source, relativeFolder: "", purpose: "", categories: ["交通", "交通"]))
    }
    func testInvoicesAlreadyInsideArchiveCanBeReorganizedWithinExplicitScopeAndUndone() throws {
        let folder = root.appendingPathComponent("10月差旅")
        let invoice = try write("旧子目录/a.txt", under: folder)
        let journal = try ArchiveJournal(file: base.appendingPathComponent("history.json"))
        let record = try journal.archiveInvoice(source: invoice, root: root,
            decision: Decision(folder: "10月差旅/出差报销/住宿", reason: "test"), sourceFolder: folder, expectedStamp: FileStamp.read(invoice))
        XCTAssertEqual(record.status, .moved)
        XCTAssertTrue(record.destination.hasSuffix("10月差旅/出差报销/住宿/a.txt"))
        try journal.undo(id: record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invoice.path))
    }
    func testScopeEscapeAndChangedFilesAreNeverMoved() throws {
        let invoice = try write("a.txt", under: source)
        let journal = try ArchiveJournal(file: base.appendingPathComponent("history.json"))
        let decision = Decision(folder: "10月差旅/出差报销/交通", reason: "test")
        XCTAssertThrowsError(try journal.archiveInvoice(source: invoice, root: root, decision: decision, sourceFolder: root))
        XCTAssertThrowsError(try journal.archiveInvoice(source: invoice, root: root, decision: Decision(folder: "别的来源/交通", reason: "test"), sourceFolder: source))
        let stamp = try FileStamp.read(invoice)
        try Data("发票已改变".utf8).write(to: invoice)
        XCTAssertThrowsError(try journal.archiveInvoice(source: invoice, root: root, decision: decision, sourceFolder: source, expectedStamp: stamp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invoice.path))
        XCTAssertTrue(journal.records.isEmpty)
    }
    func testAlreadyCorrectInvoiceDoesNotAcquireNumberSuffix() throws {
        let folder = root.appendingPathComponent("10月差旅")
        let invoice = try write("出差报销/住宿/a.txt", under: folder)
        let journal = try ArchiveJournal(file: base.appendingPathComponent("history.json"))
        let record = try journal.archiveInvoice(source: invoice, root: root,
            decision: Decision(folder: "10月差旅/出差报销/住宿", reason: "test"), sourceFolder: folder)
        XCTAssertEqual(record.status, .unchanged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invoice.path))
        XCTAssertTrue(journal.records.isEmpty)
    }
    func testDuplicateOriginalsInsideArchiveDoNotPreventFirstInvoiceBeingClassified() throws {
        let folder = root.appendingPathComponent("10月差旅")
        let first = try write("旧子目录/a.txt", under: folder)
        let second = try write("旧子目录/b.txt", under: folder)
        let originals: Set<URL> = [first, second]
        let journal = try ArchiveJournal(file: base.appendingPathComponent("history.json"))
        let decision = Decision(folder: "10月差旅/出差报销/住宿", reason: "test")
        let moved = try journal.archiveInvoice(source: first, root: root, decision: decision, sourceFolder: folder, originalFiles: originals)
        XCTAssertEqual(moved.status, .moved)
        let skipped = try journal.archiveInvoice(source: second, root: root, decision: decision, sourceFolder: folder, originalFiles: originals)
        XCTAssertEqual(skipped.status, .duplicate)
        XCTAssertEqual(skipped.destination, moved.destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
    func testAlreadyClassifiedCopyIsStillFoundEvenWhenSelectedForSameBatch() throws {
        let folder = root.appendingPathComponent("10月差旅")
        let first = try write("a.txt", under: folder)
        let classified = try write("出差报销/住宿/b.txt", under: folder)
        let journal = try ArchiveJournal(file: base.appendingPathComponent("history.json"))
        let record = try journal.archiveInvoice(source: first, root: root,
            decision: Decision(folder: "10月差旅/出差报销/住宿", reason: "test"), sourceFolder: folder, originalFiles: [first, classified])
        XCTAssertEqual(record.status, .duplicate)
        XCTAssertEqual(record.destination, classified.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }
}
