import XCTest
import SwiftUI
import DropNestCore
@testable import DropNest

@MainActor
final class WindowDragTests: XCTestCase {
    func testDropZoneClickDoesNothingAndFileURLDropArchivesFilesAndFolders() async throws {
        let suite = "DropNest-DropFlow-\(UUID())"
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let root = base.appendingPathComponent("archive")
        let folder = base.appendingPathComponent("drop-check-folder")
        let file = base.appendingPathComponent("drop-check.txt")
        let content = Data("drop verification \(UUID())".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try content.write(to: file)
        try content.write(to: folder.appendingPathComponent("nested.txt"))
        let defaults = UserDefaults(suiteName: suite)!
        var config = Configuration()
        config.rootPath = root.path
        config.useAI = false
        config.rules = [SortRule(keyword: "drop-check", folder: "验证归档")]
        defaults.set(try JSONEncoder().encode(config), forKey: "DropNest.Configuration.v1")
        _ = NSApplication.shared
        let model = AppModel(dataDirectory: base.appendingPathComponent("state"), defaults: defaults)
        let hosting = NSHostingView(rootView: DropView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DropPanelLayout.width, height: DropPanelLayout.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            window.close()
            model.clearRoot()
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
        }
        let point = NSPoint(x: hosting.bounds.midX, y: hosting.bounds.midY)
        let receiver = try XCTUnwrap(hosting.hitTest(hosting.convert(point, to: hosting.superview)) as? DropReceiver.Receiver)
        XCTAssertNil(receiver.onClick)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        receiver.mouseUp(with: event)
        XCTAssertNil(NSApplication.shared.modalWindow)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        XCTAssertTrue(pasteboard.writeObjects([file as NSURL, folder as NSURL]))
        let drag = FileURLDrag(pasteboard: pasteboard)
        XCTAssertEqual(receiver.draggingEntered(drag), .move)
        XCTAssertTrue(receiver.performDragOperation(drag))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.busy {
            guard ContinuousClock.now < deadline else { XCTFail("Dropped files did not finish archiving"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.records.filter { $0.status == .moved }.count, 2)
        let destination = root.appendingPathComponent("验证归档")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(file.lastPathComponent)), content)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(folder.lastPathComponent).appendingPathComponent("nested.txt")), content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testPanelDragRegionsLeaveControlsAndDropReceiverInteractive() async throws {
        let suite = "DropNest-DragTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: storage)
        }
        _ = NSApplication.shared
        let model = AppModel(dataDirectory: storage, defaults: defaults)
        let hosting = NSHostingView(rootView: DropView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DropPanelLayout.width, height: DropPanelLayout.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        // Allow SwiftUI to resolve the control anchors into the overlay's coordinates.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
        }
        func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
            let local = NSPoint(x: x, y: hosting.isFlipped ? y : hosting.bounds.height - y)
            return hosting.hitTest(hosting.convert(local, to: hosting.superview))
        }
        for point in [NSPoint(x: 55, y: 30), NSPoint(x: 7, y: 120),
                      NSPoint(x: 105, y: 155)] {
            XCTAssertTrue(hit(point.x, point.y) is WindowDragHandle.Handle, "Expected dragging at \(point)")
        }
        XCTAssertTrue(hit(105, 100) is DropReceiver.Receiver)
        for x: CGFloat in [161, 189] {
            XCTAssertNotNil(hit(x, 30))
            XCTAssertFalse(hit(x, 30) is WindowDragHandle.Handle, "Button must receive the click")
        }
    }
}

@MainActor
private final class FileURLDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 2
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
