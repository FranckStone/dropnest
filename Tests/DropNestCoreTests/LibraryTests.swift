import XCTest
@testable import DropNestCore

final class LibraryTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Library-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func make(_ path: String, text: String = "") throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8); return file
    }
    func testScannerLearnsCustomFoldersAndSkipsLinksAndPackages() throws {
        _ = try make("客户/星河科技/项目一/资料.txt")
        _ = try make(".secret/private.txt")
        _ = try make("Tool.app/Contents/inside.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("外部链接"), withDestinationURL: root.appendingPathComponent("客户"))
        let scanned = try LibraryScanner.scan(root: root)
        XCTAssertEqual(scanned.folders, ["客户", "客户/星河科技", "客户/星河科技/项目一"])
        XCTAssertTrue(scanned.documents.contains { $0.path == "客户/星河科技/项目一/资料.txt" })
        XCTAssertFalse(scanned.documents.contains { $0.path.contains("inside.txt") || $0.path.contains("private.txt") || $0.path.contains("外部链接") })
        XCTAssertEqual(scanned.children(of: "客户"), ["客户/星河科技"])
    }
    func testContentSearchFindsAFileWhoseNameHasNoKeyword() {
        let file = LibraryDocument(path: "客户/星河科技/资料001.txt", size: 1, modified: Date(), text: "采购合同约定：星河科技支付预付款。")
        let other = LibraryDocument(path: "客户/另一家公司/合同.txt", size: 1, modified: Date(), text: "无关信息")
        let snapshot = LibrarySnapshot(documents: [other, file])
        let results = LibrarySearch.search(snapshot, query: "星河科技 采购")
        XCTAssertEqual(results.first?.document.path, file.path)
        XCTAssertTrue(results.first?.snippet.contains("采购合同") == true)
        XCTAssertTrue(LibrarySearch.search(snapshot, query: "不存在的唯一词qzxv").isEmpty)
    }
    func testSearchByFilenameWithoutExtractedContent() {
        let file = LibraryDocument(path: "旅行/TOKYO.mov", size: 1, modified: Date())
        XCTAssertEqual(LibrarySearch.search(LibrarySnapshot(documents: [file]), query: "tokyo").first?.document.id, file.id)
    }
    func testDirectoryChoiceIsBoundToProvidedIDs() throws {
        let candidates = ["客户/星河科技", "生活/旅行"]
        let valid = Data(#"{"folder_id":1,"confident":true,"reason":"旅行订单"}"#.utf8)
        XCTAssertEqual(try ExistingFolderRouting.decode(valid, candidates: candidates)?.path, "生活/旅行")
        XCTAssertThrowsError(try ExistingFolderRouting.decode(Data(#"{"folder_id":3,"confident":true,"reason":"bad"}"#.utf8), candidates: candidates))
        XCTAssertNil(try ExistingFolderRouting.decode(Data(#"{"folder_id":-1,"confident":false,"reason":"不确定"}"#.utf8), candidates: candidates))
        XCTAssertThrowsError(try ExistingFolderRouting.decode(valid, candidates: ["safe", "../escape"]))
    }
    func testExistingDirectoryMustStillExistAtMoveTime() throws {
        let file = try make("incoming.txt", text: "important")
        let archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let journal = try ArchiveJournal(file: root.appendingPathComponent("history.json"))
        XCTAssertThrowsError(try journal.archive(source: file, root: archive,
            decision: Decision(folder: "客户/已被删除", reason: "AI", requiresExistingFolder: true)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent("客户").path))
    }
    func testScanLimitIsExplicit() throws {
        for i in 0..<5 { _ = try make("file\(i).txt") }
        let snapshot = try LibraryScanner.scan(root: root, maxEntries: 2)
        XCTAssertTrue(snapshot.incomplete); XCTAssertEqual(snapshot.documents.count, 2)
    }
    func proposal(_ folder: String, confident: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["folder": folder, "confident": confident, "reason": "按文件主题整理"])
    }
    func testNewFolderValidationRejectsEscapesAndUnhelpfulNames() throws {
        for folder in ["../outside", "/tmp/outside", "学习/../../outside", "学习\\outside", ".secret", "学习//笔记", "学习/./笔记", "a/b/c", "待整理", "其他", "学习/未分类", "测试.app", "bad:name", "bad\nname", String(repeating: "长", count: 41)] {
            XCTAssertThrowsError(try NewFolderRouting.decode(proposal(folder), parent: "", existingFolders: []), folder)
        }
        XCTAssertNil(try NewFolderRouting.decode(proposal("", confident: false), parent: "", existingFolders: []))
        XCTAssertThrowsError(try NewFolderRouting.decode(proposal("笔记"), parent: "不存在", existingFolders: []))
    }
    func testProposalReusesExistingSpellingAndRegistersAncestors() throws {
        let existing = ["Projects", "Projects/Notes"]
        let reused = try XCTUnwrap(NewFolderRouting.decode(proposal("projects/notes"), parent: "", existingFolders: existing))
        XCTAssertEqual(reused.folder, "Projects/Notes"); XCTAssertTrue(reused.requiresExistingFolder)
        let created = try XCTUnwrap(NewFolderRouting.decode(proposal("研究 / 量子计算"), parent: "", existingFolders: []))
        XCTAssertEqual(created.folder, "研究/量子计算"); XCTAssertFalse(created.requiresExistingFolder)
        var library = LibrarySnapshot()
        library.registerFolder(created.folder); library.registerFolder(created.folder)
        XCTAssertEqual(library.folders, ["研究", "研究/量子计算"])
        library.registerFolder("../escape")
        XCTAssertEqual(library.folders.count, 2)
    }
    func testProposalStripsAnAppendedSourceFilename() throws {
        let result = try XCTUnwrap(NewFolderRouting.decode(proposal("摄影/笔记001.txt"), parent: "", existingFolders: [], filename: "笔记001.txt"))
        XCTAssertEqual(result.folder, "摄影")
        XCTAssertThrowsError(try NewFolderRouting.decode(proposal("笔记001.txt"), parent: "", existingFolders: [], filename: "笔记001.txt"))
        XCTAssertThrowsError(try NewFolderRouting.decode(proposal("摄影/other.txt"), parent: "", existingFolders: [], filename: "笔记001.txt"))
    }
    func testPendingReorganizationKeepsBothUndoSteps() throws {
        let source = try make("incoming.txt", text: "important")
        let archive = root.appendingPathComponent("archive")
        let journal = try ArchiveJournal(file: root.appendingPathComponent("history.json"))
        let first = try journal.archive(source: source, root: archive, decision: Decision(folder: "待整理", reason: "旧规则"))
        let pending = URL(fileURLWithPath: first.destination)
        XCTAssertThrowsError(try journal.archive(source: pending, root: archive, decision: Decision(folder: "研究", reason: "不能通过普通入口重排")))
        let second = try journal.archivePending(source: pending, root: archive, decision: Decision(folder: "研究/摄影", reason: "新规则"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.destination))
        try journal.undo(id: second.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.destination))
        try journal.undo(id: first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testPendingReorganizationCannotRearrangeOtherFoldersOrTargetPending() throws {
        let archive = root.appendingPathComponent("archive")
        let pending = try make("archive/待整理/file.txt", text: "preserve")
        let other = try make("archive/项目/other.txt", text: "preserve")
        let nested = try make("archive/待整理/whole/nested.txt", text: "preserve")
        let journal = try ArchiveJournal(file: root.appendingPathComponent("history.json"))
        for source in [other, nested] {
            XCTAssertThrowsError(try journal.archivePending(source: source, root: archive, decision: Decision(folder: "研究", reason: "invalid")))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
        for target in ["待整理", "待整理/another"] {
            XCTAssertThrowsError(try journal.archivePending(source: pending, root: archive, decision: Decision(folder: target, reason: "invalid")))
        }
        try FileManager.default.createSymbolicLink(at: archive.appendingPathComponent("alias"), withDestinationURL: archive.appendingPathComponent("待整理"))
        XCTAssertThrowsError(try journal.archivePending(source: pending, root: archive, decision: Decision(folder: "alias", reason: "invalid")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(journal.records.isEmpty)
    }
}
