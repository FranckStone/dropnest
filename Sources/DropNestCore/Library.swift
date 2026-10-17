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

public enum LibrarySearch {
    public static func tokens(_ query: String) -> [String] {
        let normalized = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = tokens(query)
        let full = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var results: [LibrarySearchHit] = []
        for document in snapshot.documents {
            if Task.isCancelled { break }
            let path = document.path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let body = document.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            var score = 0
            if query.isEmpty { score = 1 }
            else {
                if path.contains(full) { score += 100 }
                if body.contains(full) { score += 50 }
                for term in terms {
                    if path.contains(term) { score += 12 }
                    if body.contains(term) { score += 3 }
                }
            }
            guard score > 0 else { continue }
            let firstMatch = ([full] + terms).filter { !$0.isEmpty }.compactMap { term in
                document.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
            }.min { $0.lowerBound < $1.lowerBound }
            let start = firstMatch.map { document.text.index($0.lowerBound, offsetBy: -45, limitedBy: document.text.startIndex) ?? document.text.startIndex } ?? document.text.startIndex
            let snippet = String(document.text[start...].prefix(220)).replacingOccurrences(of: "\n", with: " ")
            results.append(LibrarySearchHit(document: document, snippet: snippet, score: score))
        }
        return results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.document.modified != $1.document.modified { return $0.document.modified > $1.document.modified }
            return $0.document.path < $1.document.path
        }
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
