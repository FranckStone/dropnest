import XCTest
import DropNestCore
@testable import DropNest

@MainActor
final class DuplicateCleanupFlowTests: XCTestCase {
    func testCleanupRetainsKeeperRefreshesResultsAndProcessesQueuedDrop() async throws {
        let suite = "DropNest-CleanupFlow-\(UUID())"
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let root = base.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keeper = root.appendingPathComponent("a.txt")
        let copy = root.appendingPathComponent("b.txt")
        let incoming = base.appendingPathComponent("incoming.txt")
        try Data("identical".utf8).write(to: keeper)
        try Data("identical".utf8).write(to: copy)
        try Data("unique queued file".utf8).write(to: incoming)
        let defaults = UserDefaults(suiteName: suite)!
        var config = Configuration(); config.rootPath = root.path; config.useAI = false
        defaults.set(try JSONEncoder().encode(config), forKey: "DropNest.Configuration.v1")
        let model = AppModel(dataDirectory: base.appendingPathComponent("state"), defaults: defaults)
        defer {
            model.clearRoot()
            for moved in model.duplicateCleanupResult?.trashed ?? [] {
                if !FileManager.default.fileExists(atPath: moved.originalPath) {
                    try? FileManager.default.moveItem(atPath: moved.trashPath, toPath: moved.originalPath)
                }
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }
        model.duplicateGroups = try DuplicateFiles.groups(root: root)
        model.cleanDuplicates()
        XCTAssertTrue(model.cleaningDuplicates)
        XCTAssertTrue(model.busy)
        model.clearRoot()
        XCTAssertEqual(model.root?.path, root.path)
        model.enqueue([incoming])
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.busy || model.checkingDuplicates {
            guard ContinuousClock.now < deadline else { XCTFail("Cleanup and queued import did not finish"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.duplicateCleanupResult?.trashed.count, 1)
        XCTAssertTrue(model.duplicateCleanupResult?.issues.isEmpty == true)
        XCTAssertFalse(model.cleaningDuplicates)
        XCTAssertTrue(model.duplicateGroups.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(model.records.contains { $0.source == incoming.path && $0.status == .moved })
    }
}
