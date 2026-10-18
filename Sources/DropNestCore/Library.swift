import Foundation

public struct LibraryDocument: Codable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let modified: Date
    public var text: String
    public var textTruncated: Bool
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var ext: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
    public init(path: String, size: Int64, modified: Date, text: String = "", textTruncated: Bool = false) {
        self.path = path; self.size = size; self.modified = modified; self.text = text; self.textTruncated = textTruncated
    }
}

public struct LibrarySnapshot: Codable, Sendable {
    public var rootPath: String
    public var folders: [String]
    public var documents: [LibraryDocument]
    public var updated: Date
    public var incomplete: Bool
    public init(rootPath: String = "", folders: [String] = [], documents: [LibraryDocument] = [], updated: Date = .distantPast, incomplete: Bool = false) {
        self.rootPath = rootPath; self.folders = folders; self.documents = documents; self.updated = updated; self.incomplete = incomplete
    }
    public func children(of parent: String) -> [String] {
        folders.filter { path in
            guard path != parent else { return false }
            let components = path.split(separator: "/")
            return components.dropLast().joined(separator: "/") == parent
        }.sorted()
    }
    public func evidence(for folder: String, limit: Int = 130) -> String {
        let prefix = folder + "/"
        let matching = documents.filter { $0.path.hasPrefix(prefix) }.prefix(2)
        return String(matching.map { "\($0.name)：\(String($0.text.prefix(45)))" }.joined(separator: "；").prefix(limit))
    }
    /// Make newly created folders available to the next file in the same batch.
    public mutating func registerFolder(_ path: String) {
        guard RuleEngine.validateFolder(path) else { return }
        let components = path.split(separator: "/")
        for count in 1...components.count {
            let ancestor = components.prefix(count).joined(separator: "/")
            if !folders.contains(ancestor) { folders.append(ancestor) }
        }
        folders.sort()
    }
}

public enum LibraryScanner {
    /// Metadata only; never follows symlinks or enters application packages.
    public static func scan(root: URL, maxEntries: Int = 20_000) throws -> LibrarySnapshot {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ArchiveError.invalid("归档位置不是有效的文件夹。")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        var incomplete = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in incomplete = true; return true }) else {
            throw ArchiveError.invalid("无法读取归档目录。")
        }
        var folders: [String] = []
        var documents: [LibraryDocument] = []
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > maxEntries { incomplete = true; break }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                // FileManager does not descend into symlinks. Calling
                // skipDescendants on a non-directory can skip the next real folder.
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true && url.lastPathComponent == "node_modules" { enumerator.skipDescendants(); incomplete = true; continue }
                let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
                guard normalized.path.hasPrefix(root.path + "/") else { continue }
                let relative = String(normalized.path.dropFirst(root.path.count + 1))
                if values.isDirectory == true && values.isPackage != true {
                    if relative.split(separator: "/").count > 24 { enumerator.skipDescendants(); incomplete = true; continue }
                    if RuleEngine.validateFolder(relative) { folders.append(relative) }
                } else if values.isRegularFile == true || values.isPackage == true {
                    documents.append(LibraryDocument(path: relative, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
                }
            } catch { incomplete = true }
        }
        return LibrarySnapshot(rootPath: root.path, folders: folders.sorted(), documents: documents.sorted { $0.path < $1.path }, updated: Date(), incomplete: incomplete)
    }
}

public struct LibrarySearchHit: Identifiable, Sendable {
    public var id: String { document.id }
    public let document: LibraryDocument
    public let snippet: String
    public let score: Int
}

/// Case- and diacritic-folded copies of every path and body, computed once per
/// index refresh instead of on every keystroke.
public struct LibrarySearchIndex: Sendable {
    /// Folded UTF-8 bytes; substring tests run with memmem instead of
    /// bridging each body to UTF-16 for every term.
    fileprivate struct Entry: Sendable {
        let path: [UInt8]
        let body: [UInt8]
        /// Folding kept the character count, so a character offset in `body`
        /// is the same offset in the original text.
        let aligned: Bool
    }
    public let snapshot: LibrarySnapshot
    fileprivate let entries: [Entry]
    /// Documents whose text is unchanged since `previous` reuse its folded copy.
    public init(_ snapshot: LibrarySnapshot, reusing previous: LibrarySearchIndex? = nil) {
        var cached: [String: (text: String, entry: Entry)] = [:]
        if let previous {
            cached.reserveCapacity(previous.entries.count)
            for (document, entry) in zip(previous.snapshot.documents, previous.entries) { cached[document.path] = (document.text, entry) }
        }
        self.snapshot = snapshot
        entries = snapshot.documents.map { document in
            if let hit = cached[document.path], hit.text == document.text { return hit.entry }
            let body = LibrarySearch.fold(document.text)
            return Entry(path: Array(LibrarySearch.fold(document.path).utf8), body: Array(body.utf8), aligned: body.count == document.text.count)
        }
    }
}

public enum LibrarySearch {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    public static func tokens(_ query: String) -> [String] {
        let normalized = fold(query)
        let words = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var result = Set(words)
        for word in words {
            let characters = Array(word)
            if characters.contains(where: { $0.unicodeScalars.contains { $0.value >= 0x3400 && $0.value <= 0x9fff } }), characters.count > 2 {
                for index in 0..<(characters.count - 1) { result.insert(String(characters[index...index+1])) }
            }
        }
        return result.sorted()
    }
    public static func search(_ snapshot: LibrarySnapshot, query: String) -> [LibrarySearchHit] {
        search(LibrarySearchIndex(snapshot), query: query)
    }
    /// Snippets are built only for the first `snippetLimit` ranked hits, which
    /// is all the interface shows; later hits carry an empty snippet.
    public static func search(_ index: LibrarySearchIndex, query: String, snippetLimit: Int = 300) -> [LibrarySearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = fold(query)
        let terms = tokens(query)
        let needles = ([full] + terms).filter { !$0.isEmpty }.map { (text: $0, bytes: Array($0.utf8)) }
        let fullBytes = Array(full.utf8)
        let termBytes = terms.map { Array($0.utf8) }
        var scored: [(document: LibraryDocument, entry: LibrarySearchIndex.Entry, score: Int)] = []
        for (document, entry) in zip(index.snapshot.documents, index.entries) {
            if Task.isCancelled { break }
            var score = 0
            if query.isEmpty { score = 1 }
            else {
                if contains(entry.path, fullBytes) { score += 100 }
                if contains(entry.body, fullBytes) { score += 50 }
                for term in termBytes {
                    if contains(entry.path, term) { score += 12 }
                    if contains(entry.body, term) { score += 3 }
                }
            }
            if score > 0 { scored.append((document, entry, score)) }
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.document.modified != $1.document.modified { return $0.document.modified > $1.document.modified }
            return $0.document.path < $1.document.path
        }
        return scored.enumerated().map { offset, hit in
            LibrarySearchHit(document: hit.document, snippet: offset < snippetLimit ? snippet(hit.document.text, entry: hit.entry, needles: needles) : "", score: hit.score)
        }
    }
    private static func firstOffset(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        return haystack.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count).map { h.baseAddress!.distance(to: UnsafeRawPointer($0)) }
            }
        }
    }
    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool { firstOffset(haystack, needle) != nil }
    private static func snippet(_ text: String, entry: LibrarySearchIndex.Entry, needles: [(text: String, bytes: [UInt8])]) -> String {
        let lower: String.Index?
        if entry.aligned {
            // Locate the match in the folded bytes and carry its character offset over.
            lower = needles.compactMap { firstOffset(entry.body, $0.bytes) }.min().map { offset in
                text.index(text.startIndex, offsetBy: String(decoding: entry.body[..<offset], as: UTF8.self).count, limitedBy: text.endIndex) ?? text.startIndex
            }
        } else {
            lower = needles.compactMap { text.range(of: $0.text, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound }.min()
        }
        let start = lower.map { text.index($0, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
        return String(text[start...].prefix(220)).replacingOccurrences(of: "\n", with: " ")
    }
}

public struct FolderChoice: Sendable {
    public let path: String
    public let reason: String
}

public enum ExistingFolderRouting {
    public static func decode(_ data: Data, candidates: [String]) throws -> FolderChoice? {
        struct Reply: Decodable { let folder_id: Int; let confident: Bool; let reason: String }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.folder_id == -1 || candidates.indices.contains(reply.folder_id) else {
            throw ArchiveError.invalid("模型选择了候选列表以外的目录。")
        }
        guard reply.confident, reply.folder_id >= 0 else { return nil }
        let path = candidates[reply.folder_id]
        guard RuleEngine.validateFolder(path) else { throw ArchiveError.invalid("目录路径无效。") }
        return FolderChoice(path: path, reason: String(reply.reason.prefix(180)))
    }
}

public enum NewFolderRouting {
    public static func decode(_ data: Data, parent: String, existingFolders: [String], filename: String = "") throws -> Decision? {
        struct Reply: Decodable { let folder: String; let confident: Bool; let reason: String }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.confident else { return nil }
        guard parent.isEmpty || (RuleEngine.validateFolder(parent) && existingFolders.contains(parent)) else {
            throw ArchiveError.invalid("新目录的上级目录无效。")
        }
        guard RuleEngine.validateFolder(reply.folder) else { throw ArchiveError.invalid("AI 建议的目录路径无效。") }
        var components = reply.folder.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let sourceExtension = (filename as NSString).pathExtension.lowercased()
        // Some models append the source filename despite being asked for a folder.
        // Keep its valid topic parent; never create a directory named after the file.
        if !sourceExtension.isEmpty, components.last?.localizedCaseInsensitiveCompare(filename) == .orderedSame {
            components.removeLast()
        }
        let generic = Set(["待整理", "未分类", "其他", "其它", "杂项", "unknown", "uncategorized", "pending", "misc"])
        guard (1...2).contains(components.count), components.allSatisfy({
            !$0.isEmpty && $0.count <= 40 && !$0.contains(":") &&
            !generic.contains($0.lowercased()) &&
            (sourceExtension.isEmpty || ($0 as NSString).pathExtension.lowercased() != sourceExtension) &&
            !["app", "bundle", "framework", "photoslibrary", "rtfd", "pkg"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }),
        parent.split(separator: "/").count + components.count <= 24 else {
            throw ArchiveError.invalid("AI 建议的目录名称不符合要求。")
        }
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        var path = parent
        // Reuse existing spelling, including case and Unicode normalization.
        for component in components {
            let proposed = path.isEmpty ? component : path + "/" + component
            path = existingFolders.first { key($0) == key(proposed) } ?? proposed
        }
        guard RuleEngine.validateFolder(path) else { throw ArchiveError.invalid("AI 建议的目录路径无效。") }
        let existing = existingFolders.contains(path)
        let reason = existing ? "按现有目录归档" : "按内容自动创建目录"
        return Decision(folder: path, reason: "\(reason)：\(String(reply.reason.prefix(180)))", requiresExistingFolder: existing)
    }
}
