import XCTest
@testable import DropNestCore

final class FolderSplitTests: XCTestCase {
    private var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Split-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }
    private func write(_ relative: String) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(relative.utf8).write(to: url)
    }

    func testSplitsNestedFilesAndKeepsIndexScope() throws {
        try write("10月资料/报价单.pdf")
        try write("10月资料/合同/星河协议.docx")
        try write("10月资料/.DS_Store")
        try write("10月资料/node_modules/pkg/index.js")
        try write("10月资料/Tool.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("10月资料/空目录"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("10月资料/链接.pdf"),
                                                   withDestinationURL: base.appendingPathComponent("10月资料/报价单.pdf"))
        let folder = base.appendingPathComponent("10月资料")
        XCTAssertTrue(FolderSplit.isSplittable(folder))
        XCTAssertFalse(FolderSplit.isSplittable(base.appendingPathComponent("10月资料/Tool.app")))
        XCTAssertFalse(FolderSplit.isSplittable(base.appendingPathComponent("10月资料/报价单.pdf")))
        let items = try FolderSplit.items(in: folder, root: base.appendingPathComponent("archive"))
        XCTAssertEqual(items.map { String($0.url.path.dropFirst(folder.path.count + 1)) }, ["Tool.app", "合同/星河协议.docx", "报价单.pdf"])
        XCTAssertEqual(items.map(\.sourceFolder), ["10月资料", "10月资料/合同", "10月资料"])
    }

    func testRefusesArchiveRootAndOversizedFolders() throws {
        try write("archive/客户/a.txt")
        try write("outer/archive/b.txt")
        try write("big/1.txt"); try write("big/2.txt"); try write("big/3.txt")
        let root = base.appendingPathComponent("archive")
        XCTAssertThrowsError(try FolderSplit.items(in: root, root: root))
        XCTAssertThrowsError(try FolderSplit.items(in: root.appendingPathComponent("客户"), root: root))
        XCTAssertThrowsError(try FolderSplit.items(in: base.appendingPathComponent("outer"), root: base.appendingPathComponent("outer/archive")))
        XCTAssertThrowsError(try FolderSplit.items(in: base.appendingPathComponent("big"), root: root, limit: 2))
        XCTAssertEqual(try FolderSplit.items(in: base.appendingPathComponent("big"), root: root, limit: 3).count, 3)
    }

    func testFolderDropModeDefaultsToAskForOlderSettings() throws {
        let old = try JSONDecoder().decode(Configuration.self, from: Data(#"{"useAI":true}"#.utf8))
        XCTAssertEqual(old.folderDropMode, .ask)
        let unknown = try JSONDecoder().decode(Configuration.self, from: Data(#"{"folderDropMode":"later"}"#.utf8))
        XCTAssertEqual(unknown.folderDropMode, .ask)
        var config = Configuration(); config.folderDropMode = .split
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)).folderDropMode, .split)
    }
}
