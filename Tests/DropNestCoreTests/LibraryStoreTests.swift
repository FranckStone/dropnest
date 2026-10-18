import XCTest
@testable import DropNestCore

final class LibraryStoreTests: XCTestCase {
    private var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Store-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func snapshot(_ documents: [LibraryDocument]) -> LibrarySnapshot {
        LibrarySnapshot(rootPath: "/archive", folders: ["客户"], documents: documents, updated: Date(), incomplete: false)
    }
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testRoundTripRestoresTextAndMetadata() throws {
        var store = LibraryStore(file: base.appendingPathComponent("library.json"))
        _ = store.load()
        try store.save(snapshot([
            LibraryDocument(path: "客户/合同.txt", size: 10, modified: date, text: "采购合同 Café", textTruncated: true),
            LibraryDocument(path: "客户/空.bin", size: 3, modified: date)
        ]))
        XCTAssertEqual(store.lastWrittenShards, LibraryStore.shardCount)
        var reloaded = LibraryStore(file: store.file)
        let loaded = reloaded.load()
        XCTAssertEqual(loaded.rootPath, "/archive")
        XCTAssertEqual(loaded.folders, ["客户"])
        XCTAssertEqual(loaded.documents.map(\.path), ["客户/合同.txt", "客户/空.bin"])
        XCTAssertEqual(loaded.documents[0].text, "采购合同 Café")
        XCTAssertTrue(loaded.documents[0].textTruncated)
        XCTAssertEqual(loaded.documents[0].modified, date)
        XCTAssertEqual(loaded.documents[1].modified, date)
    }

    func testSaveRewritesOnlyChangedShards() throws {
        let file = base.appendingPathComponent("library.json")
        var store = LibraryStore(file: file)
        _ = store.load()
        let documents = (0..<200).map { LibraryDocument(path: "f/\($0).txt", size: 1, modified: date, text: "正文\($0)") }
        try store.save(snapshot(documents))

        var reloaded = LibraryStore(file: file)
        let persisted = reloaded.load().documents
        try reloaded.save(snapshot(persisted))
        XCTAssertEqual(reloaded.lastWrittenShards, 0)
        XCTAssertFalse(reloaded.lastWroteMetadata)

        var changed = documents
        changed[7].text = "修改后的正文"
        try reloaded.save(snapshot(changed))
        XCTAssertEqual(reloaded.lastWrittenShards, 1)
        XCTAssertTrue(reloaded.lastWroteMetadata)

        changed.remove(at: 7)
        try reloaded.save(snapshot(changed))
        XCTAssertEqual(reloaded.lastWrittenShards, 1)
        var final = LibraryStore(file: file)
        let loaded = final.load()
        XCTAssertEqual(loaded.documents.count, 199)
        XCTAssertFalse(loaded.documents.contains { $0.path == "f/7.txt" })
        XCTAssertTrue(loaded.documents.allSatisfy { $0.modified == date && !$0.text.isEmpty })
    }

    func testMissingShardForcesReextractionInsteadOfEmptyText() throws {
        let file = base.appendingPathComponent("library.json")
        var store = LibraryStore(file: file)
        _ = store.load()
        try store.save(snapshot([LibraryDocument(path: "a.txt", size: 1, modified: date, text: "唯一正文")]))
        let shard = store.contentDirectory.appendingPathComponent(String(format: "%02x.json", LibraryStore.shard(for: "a.txt")))
        try FileManager.default.removeItem(at: shard)
        var reloaded = LibraryStore(file: file)
        let document = try XCTUnwrap(reloaded.load().documents.first)
        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.modified, .distantPast, "stale entry must not match the file on disk")
    }

    func testLegacySingleFileIndexIsMigratedOnNextSave() throws {
        let file = base.appendingPathComponent("library.json")
        struct Legacy: Encodable { let version: Int; let snapshot: LibrarySnapshot }
        let legacy = snapshot([LibraryDocument(path: "旧/文件.txt", size: 2, modified: date, text: "旧版正文")])
        try JSONEncoder().encode(Legacy(version: 1, snapshot: legacy)).write(to: file)
        var store = LibraryStore(file: file)
        let loaded = store.load()
        XCTAssertEqual(loaded.documents.first?.text, "旧版正文")
        try store.save(loaded)
        XCTAssertEqual(store.lastWrittenShards, LibraryStore.shardCount)
        var reloaded = LibraryStore(file: file)
        XCTAssertEqual(reloaded.load().documents.first?.text, "旧版正文")
    }

    func testSearchIndexReusesUnchangedEntriesAndRefoldsChangedOnes() {
        let first = snapshot([
            LibraryDocument(path: "Notes/Résumé.txt", size: 1, modified: date, text: "CAFÉ 预算"),
            LibraryDocument(path: "b.txt", size: 1, modified: date, text: "旧词")
        ])
        let index = LibrarySearchIndex(first)
        XCTAssertEqual(LibrarySearch.search(index, query: "resume").first?.document.path, "Notes/Résumé.txt")
        XCTAssertEqual(LibrarySearch.search(index, query: "cafe").first?.document.path, "Notes/Résumé.txt")

        var second = first
        second.documents[1].text = "新词"
        let next = LibrarySearchIndex(second, reusing: index)
        XCTAssertTrue(LibrarySearch.search(next, query: "旧词").isEmpty)
        XCTAssertEqual(LibrarySearch.search(next, query: "新词").first?.document.path, "b.txt")
        XCTAssertEqual(LibrarySearch.search(next, query: "cafe").first?.document.path, "Notes/Résumé.txt")
    }

    func testSnippetStartsNearTheFoldedMatchInTheOriginalText() {
        let text = String(repeating: "前言内容。", count: 40) + "附件：ÉTUDE Café 采购合同" + String(repeating: "结尾。", count: 80)
        let index = LibrarySearchIndex(snapshot([LibraryDocument(path: "a.txt", size: 1, modified: date, text: text)]))
        let snippet = LibrarySearch.search(index, query: "etude cafe").first?.snippet ?? ""
        XCTAssertTrue(snippet.contains("ÉTUDE Café 采购合同"), snippet)
        XCTAssertFalse(snippet.hasPrefix("前言内容。前言内容。前言内容。前言内容。前言内容。前言内容。前言内容。前言内容。前言内容。前言内容。"), snippet)
        XCTAssertEqual(LibrarySearch.search(index, query: "合同", snippetLimit: 0).first?.snippet, "")
    }
}
