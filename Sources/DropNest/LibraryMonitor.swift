import Foundation
import CoreServices
import Darwin
import DropNestCore

/// FSEvents watches the whole tree without opening a descriptor for every folder.
/// The stream and debounce timer both deliver on the main actor.
@MainActor
final class LibraryMonitor {
    private final class Handler {
        let receive: @MainActor ([String], [FSEventStreamEventFlags]) -> Void
        init(receive: @escaping @MainActor ([String], [FSEventStreamEventFlags]) -> Void) {
            self.receive = receive
        }
    }

    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?
    private var firstChange: ContinuousClock.Instant?
    private let root: String
    private let excludedPaths: [String]
    private let onChange: () -> Void

    init(root: URL, excluding: [URL] = [], onChange: @escaping () -> Void) throws {
        self.root = Self.eventPath(root)
        self.excludedPaths = excluding.map(Self.eventPath)
        self.onChange = onChange
        let handler = Handler { [weak self] paths, flags in self?.receive(paths: paths, flags: flags) }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                if let info { Unmanaged<Handler>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as! [String]
            let eventFlags = Array(UnsafeBufferPointer(start: flags, count: count))
            MainActor.assumeIsolated { handler.receive(paths, eventFlags) }
        }, &context, [self.root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else {
            throw ArchiveError.invalid("无法监听归档目录；可使用“刷新索引”手动更新。")
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            throw ArchiveError.invalid("无法启动文件变化监听；可使用“刷新索引”手动更新。")
        }
        self.stream = stream
    }

    func stop() {
        pending?.cancel(); pending = nil; firstChange = nil
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
    }

    private static func eventPath(_ url: URL) -> String {
        // FSEvents uses physical paths such as /private/var. Foundation can
        // shorten these to /var only while a file exists, so normalizing each
        // event with URL would discard deletions and moves out of the tree.
        var path = url.path
        var missingComponents: [String] = []
        while true {
            if let resolved = realpath(path, nil) {
                defer { free(resolved) }
                return missingComponents.reversed().reduce(String(cString: resolved)) {
                    ($0 == "/" ? "" : $0) + "/" + $1
                }
            }
            guard path != "/" else { return url.path }
            missingComponents.append((path as NSString).lastPathComponent)
            path = (path as NSString).deletingLastPathComponent
        }
    }

    private func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard stream != nil else { return }
        let recoveryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped |
            kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        let relevant = zip(paths, flags).contains { path, flag in
            if flag & recoveryFlags != 0 { return true }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { return false }
            guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { return false }
            guard !excludedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
            let relative = path.dropFirst(root.count).split(separator: "/")
            return !relative.contains { $0.hasPrefix(".") || $0 == "node_modules" }
        }
        guard relevant else { return }
        let now = ContinuousClock.now
        if firstChange == nil { firstChange = now }
        // Wait for a burst to settle, but keep updating during a long copy operation.
        let deadline = min(now.advanced(by: .milliseconds(600)), firstChange!.advanced(by: .seconds(3)))
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, self.stream != nil else { return }
            self.pending = nil; self.firstChange = nil
            self.onChange()
        }
    }
}
