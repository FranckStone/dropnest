import XCTest
import Combine
import DropNestCore
@testable import DropNest

@MainActor
final class LibraryMonitorTests: XCTestCase {
    private func waitUntil(_ description: String, condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out: \(description)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func makeModel(root: URL, storage: URL) throws -> (AppModel, UserDefaults, String) {
        let suite = "DropNest-MonitorTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        var config = Configuration(); config.rootPath = root.path; config.useAI = false
        defaults.set(try JSONEncoder().encode(config), forKey: "DropNest.Configuration.v1")
        return (AppModel(dataDirectory: storage, defaults: defaults), defaults, suite)
    }

    func testFinderStyleChangesAutomaticallyRefreshIndexAndSearch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Watch-\(UUID())")
        let root = base.appendingPathComponent("archive")
        let nested = root.appendingPathComponent("客户/项目资料")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let (model, defaults, suite) = try makeModel(root: root, storage: base.appendingPathComponent("state"))
        defer { model.clearRoot(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) }
        XCTAssertTrue(model.monitoringLibrary, model.error ?? "File monitoring did not start")
        try await waitUntil("initial scan") { !model.indexing }
        model.searchQuery = "采购合同"; model.searchLibrary()

        let file = nested.appendingPathComponent("001.txt")
        try "采购合同第一版".write(to: file, atomically: true, encoding: .utf8)
        try await waitUntil("new nested file appears in current search") {
            model.searchResults.first?.document.path == "客户/项目资料/001.txt"
        }

        // Editors commonly save by atomically replacing the original file.
        try "旅行预订确认信息第二版".write(to: file, atomically: true, encoding: .utf8)
        try await waitUntil("old body removed from current search") {
            !model.indexing && !model.searching && model.searchResults.isEmpty &&
                model.library.documents.first?.text.contains("旅行预订") == true
        }
        model.searchQuery = "旅行预订"; model.searchLibrary()
        try await waitUntil("new body is searchable") { model.searchResults.count == 1 }

        let renamed = root.appendingPathComponent("行程")
        try FileManager.default.moveItem(at: nested, to: renamed)
        try await waitUntil("renamed directory updates descendant paths") {
            model.searchResults.first?.document.path == "行程/001.txt" && model.library.folders.contains("行程")
        }
        let renamedFile = renamed.appendingPathComponent("002.txt")
        try FileManager.default.moveItem(at: renamed.appendingPathComponent("001.txt"), to: renamedFile)
        try await waitUntil("renamed file updates search") { model.searchResults.first?.document.name == "002.txt" }

        let movedOut = base.appendingPathComponent("outside.txt")
        try FileManager.default.moveItem(at: renamedFile, to: movedOut)
        try await waitUntil("file moved outside disappears") {
            model.library.documents.isEmpty && model.searchResults.isEmpty
        }
        try FileManager.default.moveItem(at: movedOut, to: renamedFile)
        try await waitUntil("file moved back appears") { model.searchResults.count == 1 }
        try FileManager.default.removeItem(at: renamed)
        try await waitUntil("deleted folder and content disappear") {
            !model.library.folders.contains("行程") && model.library.documents.isEmpty && model.searchResults.isEmpty
        }
    }

    func testSwitchingAndClearingRootStopsOldWatcher() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-SwitchWatch-\(UUID())")
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let (model, defaults, suite) = try makeModel(root: first, storage: base.appendingPathComponent("state"))
        defer { model.clearRoot(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) }
        try await waitUntil("first root indexed") { !model.indexing }
        // Switch while the old root has a change waiting to be delivered.
        try "old".write(to: first.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        model.setRoot(second)
        try await waitUntil("second root indexed") { !model.indexing && model.library.rootPath == second.path }
        try "new".write(to: second.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await waitUntil("new root watched") { model.library.documents.first?.name == "new.txt" }
        let updated = model.library.updated
        try "ignored".write(to: first.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(model.library.updated, updated)

        model.clearRoot()
        XCTAssertFalse(model.monitoringLibrary)
        try "after clearing".write(to: second.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(model.library.updated, .distantPast)
        XCTAssertFalse(model.indexing)
        XCTAssertTrue(model.searchResults.isEmpty)
    }

    func testIndexWritesDoNotTriggerAnEndlessRefreshLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-SelfWatch-\(UUID())")
        let storage = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (model, defaults, suite) = try makeModel(root: root, storage: storage)
        defer { model.clearRoot(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try await waitUntil("initial scan complete") { !model.indexing }
        // Establish the stream and let the initial write events settle.
        try await Task.sleep(for: .seconds(2))
        let updated = model.library.updated
        try "internal data".write(to: storage.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(model.library.updated, updated)
        XCTAssertFalse(model.indexing)
        try "visible content".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try await waitUntil("real file changes still update") { model.library.documents.contains { $0.name == "visible.txt" } }
    }

    func testRefreshRequestedDuringIndexingRunsAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-Rescan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "first".write(to: root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        let (model, defaults, suite) = try makeModel(root: root, storage: root.appendingPathComponent("state"))
        defer { model.clearRoot(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var inserted = false
        var writeError: Error?
        // Progress is delivered after directory enumeration, so this file is
        // deliberately absent from the first scan's metadata snapshot.
        let subscription = model.$indexProgress.sink { progress in
            guard progress.hasPrefix("正在建立内容索引"), !inserted else { return }
            inserted = true
            do { try "late arrival".write(to: root.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8) }
            catch { writeError = error }
            model.refreshLibrary()
        }
        defer { subscription.cancel() }
        try await waitUntil("queued refresh picks up file created during indexing") {
            !model.indexing && model.library.documents.contains { $0.name == "late.txt" }
        }
        XCTAssertTrue(inserted); XCTAssertNil(writeError)
    }
}
