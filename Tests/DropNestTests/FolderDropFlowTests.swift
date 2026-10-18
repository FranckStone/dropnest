import XCTest
import DropNestCore
@testable import DropNest

@MainActor
final class FolderDropFlowTests: XCTestCase {
    private func makeModel(_ mode: FolderDropMode) throws -> (AppModel, URL, URL, () -> Void) {
        let suite = "DropNest-FolderDrop-\(UUID())"
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(suite).resolvingSymlinksInPath()
        let root = base.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: suite)!
        var config = Configuration(); config.rootPath = root.path; config.useAI = false; config.folderDropMode = mode
        defaults.set(try JSONEncoder().encode(config), forKey: "DropNest.Configuration.v1")
        let model = AppModel(dataDirectory: base.appendingPathComponent("state"), defaults: defaults)
        return (model, base, root, { model.clearRoot(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) })
    }
    private func dropFolder(in base: URL) throws -> URL {
        let folder = base.appendingPathComponent("资料包")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        try Data("一".utf8).write(to: folder.appendingPathComponent("甲.txt"))
        try Data("二".utf8).write(to: folder.appendingPathComponent("子目录/乙.txt"))
        return folder
    }
    private func waitIdle(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.busy {
            guard ContinuousClock.now < deadline else { XCTFail("Queue did not finish"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testSplitArchivesEachFileAndKeepsEmptyFolders() async throws {
        let (model, base, root, cleanup) = try makeModel(.ask)
        defer { cleanup() }
        let folder = try dropFolder(in: base)
        let loose = base.appendingPathComponent("单独.txt"); try Data("三".utf8).write(to: loose)
        XCTAssertTrue(model.needsFolderChoice([folder, loose]))
        XCTAssertFalse(model.needsFolderChoice([loose]))
        model.enqueueDrop([folder, loose], split: true)
        try await waitIdle(model)
        let pending = root.appendingPathComponent("待整理")
        for name in ["甲.txt", "乙.txt", "单独.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: pending.appendingPathComponent(name).path), name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("子目录").path), "emptied folders stay in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.appendingPathComponent("资料包").path))
        let moved = model.records.filter { $0.status == .moved }
        XCTAssertEqual(moved.count, 3)
        // Undo returns each file to its original subfolder.
        let nested = try XCTUnwrap(moved.first { $0.name == "乙.txt" })
        model.undo(nested)
        try await waitIdle(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("子目录/乙.txt").path))
    }

    func testFixedModesSkipTheQuestion() async throws {
        let (model, base, root, cleanup) = try makeModel(.whole)
        defer { cleanup() }
        let folder = try dropFolder(in: base)
        XCTAssertFalse(model.needsFolderChoice([folder]))
        model.handleDrop([folder])
        try await waitIdle(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("待整理/资料包/子目录/乙.txt").path))

        model.config.folderDropMode = .split
        XCTAssertFalse(model.needsFolderChoice([folder]))
        let second = base.appendingPathComponent("第二批")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("四".utf8).write(to: second.appendingPathComponent("丙.txt"))
        model.handleDrop([second])
        try await waitIdle(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("待整理/丙.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}
