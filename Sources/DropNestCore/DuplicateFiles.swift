import Foundation
import DropNestRust

public struct DuplicateGroup: Identifiable, Sendable {
    public var id: String { documents[0].path }
    public let documents: [LibraryDocument]
    public let contentDigest: Data
    public let stamps: [String: FileStamp]
}

public enum DuplicateFiles {
    private static func digest(_ url: URL) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = url.withUnsafeFileSystemRepresentation { path in dn_sha256_file(path, &bytes) }
        guard result == 0 else { throw unreadable(url) }
        return Data(bytes)
    }

    private static func identical(_ left: URL, _ right: URL) throws -> Bool {
        let result = left.withUnsafeFileSystemRepresentation { a in
            right.withUnsafeFileSystemRepresentation { b in dn_files_equal(a, b) }
        }
        guard result >= 0 else { throw unreadable(right) }
        return result == 1
    }

    private static func unreadable(_ url: URL) -> ArchiveError {
        .invalid("无法完成重复检查，文件不可读或检查期间发生变化：\(url.lastPathComponent)。原文件已保留。")
    }

    /// Same scope as indexing: visible regular files, excluding links, packages and node_modules.
    private static func inventory(root: URL) throws -> [LibraryDocument] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ArchiveError.invalid("归档位置不是文件夹。")
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                        .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        var readError: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                readError = error; return false
            }) else { throw ArchiveError.invalid("无法读取归档目录，重复检查未完成。") }
        var documents: [LibraryDocument] = []
        var count = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            guard count <= 20_000 else { throw ArchiveError.invalid("归档目录超过 20,000 个条目，重复检查未完成，原文件已保留。") }
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if values.isPackage == true || url.lastPathComponent == "node_modules" { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard normalized.path.hasPrefix(root.path + "/") else {
                throw ArchiveError.invalid("归档目录在检查期间发生变化，请刷新后重试。")
            }
            documents.append(LibraryDocument(path: String(normalized.path.dropFirst(root.path.count + 1)),
                size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
        }
        if let readError { throw ArchiveError.invalid("部分目录不可读，重复检查未完成：\(readError.localizedDescription)") }
        return documents.sorted { $0.path < $1.path }
    }

    private static func file(_ document: LibraryDocument, root: URL) throws -> URL {
        let url = root.appendingPathComponent(document.path)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw ArchiveError.invalid("文件已不在归档范围内，请刷新后重试。")
        }
        return url
    }

    public static func match(source: URL, root: URL, excludingOriginals: Set<URL> = [], destinationFolder: URL? = nil) throws -> URL? {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let before = try FileStamp.read(source)
        func verified(_ result: URL?) throws -> URL? {
            guard try FileStamp.read(source) == before else { throw unreadable(source) }
            return result
        }
        let candidates = try inventory(root: root).filter {
            let candidate = root.appendingPathComponent($0.path)
            // Other originals in a selected invoice batch are not yet archived copies.
            // Files already in the intended classification folder still count as matches.
            return $0.size == Int64(values.fileSize ?? 0) && candidate.path != source.path &&
                (!excludingOriginals.contains(candidate) || candidate.deletingLastPathComponent() == destinationFolder)
        }
        guard !candidates.isEmpty else { return try verified(nil) }
        let sourceDigest = try digest(source)
        for document in candidates {
            try Task.checkCancellation()
            let candidate = try file(document, root: root)
            if try digest(candidate) == sourceDigest, try identical(source, candidate) { return try verified(candidate) }
        }
        return try verified(nil)
    }

    public static func groups(root: URL, progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> [DuplicateGroup] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let bySize = Dictionary(grouping: try inventory(root: root), by: \.size)
        let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        var byDigest: [Data: [[LibraryDocument]]] = [:]
        var stamps: [String: FileStamp] = [:]
        for (index, document) in candidates.enumerated() {
            try Task.checkCancellation()
            let url = try file(document, root: root)
            let before = try FileStamp.read(url)
            guard before.size == UInt64(document.size), before.modified == document.modified else { throw unreadable(url) }
            let hash = try digest(url)
            guard try FileStamp.read(url) == before else { throw unreadable(url) }
            stamps[document.path] = before
            var groups = byDigest[hash] ?? []
            var match: Int?
            for group in groups.indices {
                if try identical(url, file(groups[group][0], root: root)) { match = group; break }
            }
            if let match { groups[match].append(document) }
            else { groups.append([document]) }
            byDigest[hash] = groups
            if index % 10 == 0 || index + 1 == candidates.count { progress(index + 1, candidates.count) }
        }
        return byDigest.flatMap { digest, groups in
            groups.filter { $0.count > 1 }.map { documents in
                DuplicateGroup(documents: documents, contentDigest: digest,
                    stamps: Dictionary(uniqueKeysWithValues: documents.map { ($0.path, stamps[$0.path]!) }))
            }
        }.sorted { $0.id < $1.id }
    }

    /// Checks the scan snapshot and the current bytes again immediately before a Trash operation.
    static func verifiedCleanupPair(keeper: LibraryDocument, duplicate: LibraryDocument,
                                    group: DuplicateGroup, root: URL) throws -> (URL, URL) {
        func checked(_ document: LibraryDocument) throws -> URL {
            let components = document.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !document.path.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw ArchiveError.invalid("文件路径无效，已跳过。")
            }
            let url = try file(document, root: root)
            guard url.path == url.resolvingSymlinksInPath().path,
                  let expected = group.stamps[document.path], try FileStamp.read(url) == expected,
                  try digest(url) == group.contentDigest else {
                throw ArchiveError.invalid("文件自检查后已变化或已被替换，请重新检查。")
            }
            return url
        }
        let kept = try checked(keeper)
        let removed = try checked(duplicate)
        guard kept != removed, try identical(kept, removed),
              try FileStamp.read(kept) == group.stamps[keeper.path],
              try FileStamp.read(removed) == group.stamps[duplicate.path] else {
            throw ArchiveError.invalid("文件内容或位置已变化，已跳过。")
        }
        return (kept, removed)
    }
}
