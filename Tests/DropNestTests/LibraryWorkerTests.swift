import XCTest
import DropNestCore
@testable import DropNest

final class LibraryWorkerTests: XCTestCase {
    func testArchiveSearchAndUndoWithAnExistingCustomFolder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Flow-\(UUID())")
        let root = base.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("客户/星河/项目资料"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("document.txt")
        try "采购合同唯一编号 SH-2026-17".write(to: source, atomically: true, encoding: .utf8)
        let journal = try ArchiveJournal(file: base.appendingPathComponent("history.json"))
        let record = try journal.archive(source: source, root: root,
            decision: Decision(folder: "客户/星河/项目资料", reason: "已选择存在目录", requiresExistingFolder: true))
        let worker = LibraryWorker(storage: base.appendingPathComponent("index.json"))
        let snapshot = try await worker.rebuild(root: root) { _, _ in }
        let results = await worker.search(query: "SH-2026-17", root: snapshot.rootPath)
        XCTAssertEqual(results.first?.document.path, "客户/星河/项目资料/document.txt")
        XCTAssertTrue(record.destination.hasSuffix("客户/星河/项目资料/document.txt"))
        try journal.undo(id: record.id)
        _ = try await worker.rebuild(root: root) { _, _ in }
        let afterUndo = await worker.search(query: "SH-2026-17", root: snapshot.rootPath)
        XCTAssertTrue(afterUndo.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testIndexSearchRefreshAndPersistence() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Index-\(UUID())")
        let root = base.appendingPathComponent("files")
        let storage = base.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("客户/星河"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("客户/星河/001.txt")
        try "本期采购合同，预付款金额100元。".write(to: file, atomically: true, encoding: .utf8)
        let worker = LibraryWorker(storage: storage)
        let first = try await worker.rebuild(root: root) { _, _ in }
        XCTAssertTrue(first.documents.first?.text.contains("采购合同") == true)
        let hits = await worker.search(query: "预付款", root: root.path)
        XCTAssertEqual(hits.first?.document.path, "客户/星河/001.txt")
        let loaded = LibraryWorker(storage: storage)
        let persisted = await loaded.search(query: "预付款", root: root.path)
        XCTAssertEqual(persisted.count, 1)
        try FileManager.default.removeItem(at: file)
        _ = try await worker.rebuild(root: root) { _, _ in }
        let removed = await worker.search(query: "预付款", root: root.path)
        XCTAssertTrue(removed.isEmpty)
    }
    func testUnchangedRebuildDoesNotRewriteContentShards() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Shards-\(UUID())")
        let root = base.appendingPathComponent("files")
        let storage = base.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for number in 0..<20 { try "第\(number)份报告".write(to: root.appendingPathComponent("\(number).txt"), atomically: true, encoding: .utf8) }
        _ = try await LibraryWorker(storage: storage).rebuild(root: root) { _, _ in }
        let worker = LibraryWorker(storage: storage)
        _ = try await worker.rebuild(root: root) { _, _ in }
        let unchanged = await worker.lastWrittenShards
        XCTAssertEqual(unchanged, 0)
        try "新增的季度预算".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        _ = try await worker.rebuild(root: root) { _, _ in }
        let added = await worker.lastWrittenShards
        XCTAssertEqual(added, 1)
        let hits = await worker.search(query: "季度预算", root: root.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(hits.first?.document.path, "new.txt")
    }
    func testPlainTextExtractionIsBounded() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Text-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try String(repeating: "采购合同", count: 200).write(to: file, atomically: true, encoding: .utf8)
        let extracted = FileTextExtractor.extract(file, limit: 100)
        XCTAssertEqual(extracted.text.count, 100); XCTAssertTrue(extracted.truncated)
    }
    func testOfficeArchivesAreReadInProcess() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Office-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        func pack(_ name: String, _ entries: [String: String]) throws -> URL {
            let folder = base.appendingPathComponent(name + "-src")
            for (path, body) in entries {
                let url = folder.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: url, atomically: true, encoding: .utf8)
            }
            let output = base.appendingPathComponent(name)
            let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.arguments = ["-qr", output.path, "."]; zip.currentDirectoryURL = folder
            try zip.run(); zip.waitUntilExit()
            XCTAssertEqual(zip.terminationStatus, 0)
            return output
        }
        let xlsx = try pack("报表.xlsx", ["xl/sharedStrings.xml": "<sst><si><t>客户 &amp; 预算</t></si></sst>",
                                         "xl/worksheets/sheet1.xml": "<w><c><v>2026</v></c></w>",
                                         "docProps/core.xml": "<t>不应出现</t>"])
        let sheet = FileTextExtractor.extract(xlsx)
        XCTAssertEqual(sheet.text, "客户 & 预算 \n2026 \n"); XCTAssertFalse(sheet.truncated)
        let pptx = try pack("汇报.pptx", ["ppt/slides/slide1.xml": "<p:sld><a:t>季度汇报</a:t></p:sld>"])
        XCTAssertTrue(FileTextExtractor.extract(pptx).text.contains("季度汇报"))
        XCTAssertTrue(FileTextExtractor.extract(xlsx, limit: 3).truncated)
        let fake = base.appendingPathComponent("假.xlsx")
        try "not a zip".write(to: fake, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileTextExtractor.extract(fake).text, "")
    }
    func testRTFExtraction() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-RTF-\(UUID()).rtf")
        defer { try? FileManager.default.removeItem(at: file) }
        try #"{\rtf1\ansi Customer Contract invoice 123}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileTextExtractor.extract(file).text.contains("Customer Contract"))
    }
    func testHTMLIndexesReadableBodyInsteadOfStyleAndScript() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-HTML-\(UUID()).html")
        defer { try? FileManager.default.removeItem(at: file) }
        try "<html><head><style>unwanted_css</style><script>unwanted_script</script></head><body><h1>采购报告</h1><p>金额 &amp; 税率 &#x5408;同</p></body></html>".write(to: file, atomically: true, encoding: .utf8)
        let result = FileTextExtractor.extract(file)
        XCTAssertTrue(result.text.contains("采购报告")); XCTAssertTrue(result.text.contains("& 税率 合同"))
        XCTAssertFalse(result.text.contains("unwanted")); XCTAssertFalse(result.text.contains("<h1>"))
    }
}
