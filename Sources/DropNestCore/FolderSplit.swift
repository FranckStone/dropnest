import Foundation

/// One file taken out of a dropped folder to be classified on its own.
public struct SplitItem: Sendable, Equatable {
    public let url: URL
    /// Dropped folder name plus the file's subfolders, e.g. `10月资料/合同`.
    /// Passed to the classifier as a hint; the folders themselves stay in place.
    public let sourceFolder: String
}

public enum FolderSplit {
    public static let limit = 2_000

    /// A real folder: not a symlink and not a package such as `.app`, which
    /// always moves as one item.
    public static func isSplittable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true
    }

    /// Files inside `folder`, sorted by path. Follows the index's scope: hidden
    /// entries, symlinks and `node_modules` are left where they are; packages
    /// are returned as single items. Empty folders are kept, never deleted.
    public static func items(in folder: URL, root: URL?, limit: Int = limit) throws -> [SplitItem] {
        guard isSplittable(folder) else { throw ArchiveError.invalid("只能拆分普通文件夹。") }
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        if let root {
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            if folder == root || root.path.hasPrefix(folder.path + "/") {
                throw ArchiveError.invalid("不能拆分归档目录或包含它的文件夹。")
            }
            if folder.path.hasPrefix(root.path + "/") {
                throw ArchiveError.invalid("「\(folder.lastPathComponent)」已在归档目录中，无法拆分；重新整理请使用「重新整理待整理」。")
            }
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        var unreadable = false
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in unreadable = true; return true }) else {
            throw ArchiveError.invalid("无法读取文件夹「\(folder.lastPathComponent)」。")
        }
        var items: [SplitItem] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys) else { unreadable = true; continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true && values.isPackage != true {
                if url.lastPathComponent == "node_modules" { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true || values.isPackage == true else { continue }
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(folder.path + "/") else { continue }
            items.append(SplitItem(url: file, sourceFolder: sourceFolder(of: file, in: folder)))
            if items.count > limit {
                throw ArchiveError.invalid("「\(folder.lastPathComponent)」中超过 \(limit) 个文件，请分批拖入，或选择整体归档。")
            }
        }
        if unreadable && items.isEmpty {
            throw ArchiveError.invalid("文件夹「\(folder.lastPathComponent)」不可读。")
        }
        return items.sorted { $0.url.path < $1.url.path }
    }

    private static func sourceFolder(of file: URL, in folder: URL) -> String {
        let parent = file.deletingLastPathComponent().path
        let inner = parent == folder.path ? "" : String(parent.dropFirst(folder.path.count + 1))
        return inner.isEmpty ? folder.lastPathComponent : folder.lastPathComponent + "/" + inner
    }
}
