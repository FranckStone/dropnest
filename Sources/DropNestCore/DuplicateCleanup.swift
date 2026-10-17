import Foundation

public struct DuplicateCleanupIssue: Sendable {
    public let path: String
    public let message: String
}

public struct TrashedDuplicate: Codable, Sendable {
    public let originalPath: String
    public let trashPath: String
    public let keptPath: String
    public let date: Date
}

public struct DuplicateCleanupResult: Sendable {
    public var trashed: [TrashedDuplicate] = []
    public var issues: [DuplicateCleanupIssue] = []
    public var summary: String {
        "已将 \(trashed.count) 个重复文件移到废纸篓" + (issues.isEmpty ? "，每组保留一份。" : "，\(issues.count) 个未清理。")
    }
}

public enum DuplicateCleanup {
    public static func systemTrash(_ url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        // A successful Trash operation must never be retried solely because its URL was unavailable.
        return resultingURL as URL? ?? url
    }

    /// Only removes entries from the supplied scan; it never adds new matches during cleanup.
    public static func clean(groups: [DuplicateGroup], root: URL,
                             trash: (URL) throws -> URL = systemTrash,
                             progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> DuplicateCleanupResult {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let keepers = Set(groups.compactMap { $0.documents.first?.path })
        let total = groups.reduce(0) { $0 + max(0, $1.documents.count - 1) }
        var result = DuplicateCleanupResult()
        var processed = Set<String>()
        var completed = 0
        for group in groups {
            guard let keeper = group.documents.first else { continue }
            for document in group.documents.dropFirst() {
                do {
                    try Task.checkCancellation()
                    guard !keepers.contains(document.path), !processed.contains(document.path) else {
                        throw ArchiveError.invalid("此文件需要保留，或已处理，已跳过。")
                    }
                    let (kept, removed) = try DuplicateFiles.verifiedCleanupPair(
                        keeper: keeper, duplicate: document, group: group, root: root)
                    let trashed = try trash(removed)
                    processed.insert(document.path)
                    result.trashed.append(TrashedDuplicate(originalPath: removed.path, trashPath: trashed.path,
                        keptPath: kept.path, date: Date()))
                } catch {
                    result.issues.append(DuplicateCleanupIssue(path: document.path, message: error.localizedDescription))
                }
                completed += 1
                progress(completed, total)
            }
        }
        return result
    }
}
