import Foundation

/// Persists a library snapshot as a small metadata file plus hashed text shards,
/// so a rebuild rewrites only the shards whose documents actually changed.
public struct LibraryStore: Sendable {
    public static let shardCount = 64
    private static let formatVersion = 2

    private struct StoredDocument: Codable, Equatable, Sendable {
        let path: String
        let size: Int64
        let modified: Date
        let textTruncated: Bool
        /// UTF-8 length of the text written to the shard; detects a shard and
        /// metadata file that were left out of step by an interrupted save.
        let textLength: Int
    }
    private struct StoredMeta: Codable {
        let version: Int
        let rootPath: String
        let folders: [String]
        let documents: [StoredDocument]
        let updated: Date
        let incomplete: Bool
    }
    private struct VersionProbe: Decodable { let version: Int }
    private struct LegacyIndex: Decodable { let snapshot: LibrarySnapshot }

    public let file: URL
    public var contentDirectory: URL {
        file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-content", isDirectory: true)
    }
    /// Shards rewritten by the most recent save; exposed for tests.
    public private(set) var lastWrittenShards = 0
    public private(set) var lastWroteMetadata = false

    private var persistedRoot = ""
    private var persistedTexts: [String: String] = [:]
    private var persistedFolders: [String] = []
    private var persistedDocuments: [StoredDocument] = []
    private var persistedIncomplete = false
    private var needsFullWrite = true

    public init(file: URL) { self.file = file }

    public static func shard(for path: String) -> Int {
        // FNV-1a: stable across launches, unlike Hasher.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(shardCount))
    }

    private func shardURL(_ shard: Int) -> URL {
        contentDirectory.appendingPathComponent(String(format: "%02x.json", shard))
    }

    public mutating func load() -> LibrarySnapshot {
        needsFullWrite = true
        guard let data = try? Data(contentsOf: file),
              let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else { return LibrarySnapshot() }
        if probe.version == 1 {
            // Single-file index from earlier releases; the next save migrates it.
            return (try? JSONDecoder().decode(LegacyIndex.self, from: data))?.snapshot ?? LibrarySnapshot()
        }
        guard probe.version == Self.formatVersion, let meta = try? JSONDecoder().decode(StoredMeta.self, from: data) else {
            return LibrarySnapshot()
        }
        var texts: [String: String] = [:]
        for shard in 0..<Self.shardCount {
            guard let data = try? Data(contentsOf: shardURL(shard)),
                  let stored = try? JSONDecoder().decode([String: String].self, from: data) else { continue }
            texts.merge(stored) { _, new in new }
        }
        let documents = meta.documents.map { stored -> LibraryDocument in
            let text = texts[stored.path] ?? ""
            // A missing or mismatched shard forces re-extraction instead of
            // trusting the file as unchanged with empty text.
            guard text.utf8.count == stored.textLength else {
                return LibraryDocument(path: stored.path, size: stored.size, modified: .distantPast)
            }
            return LibraryDocument(path: stored.path, size: stored.size, modified: stored.modified, text: text, textTruncated: stored.textTruncated)
        }
        persistedRoot = meta.rootPath
        persistedTexts = texts
        persistedFolders = meta.folders
        persistedDocuments = meta.documents
        persistedIncomplete = meta.incomplete
        needsFullWrite = false
        return LibrarySnapshot(rootPath: meta.rootPath, folders: meta.folders, documents: documents, updated: meta.updated, incomplete: meta.incomplete)
    }

    public mutating func save(_ snapshot: LibrarySnapshot) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        var texts: [String: String] = [:]
        texts.reserveCapacity(snapshot.documents.count)
        for document in snapshot.documents where !document.text.isEmpty { texts[document.path] = document.text }

        let full = needsFullWrite || persistedRoot != snapshot.rootPath
        var dirty = Set<Int>()
        if full { dirty = Set(0..<Self.shardCount) }
        else {
            for (path, text) in texts where persistedTexts[path] != text { dirty.insert(Self.shard(for: path)) }
            for path in persistedTexts.keys where texts[path] == nil { dirty.insert(Self.shard(for: path)) }
        }
        let documents = snapshot.documents.map {
            StoredDocument(path: $0.path, size: $0.size, modified: $0.modified, textTruncated: $0.textTruncated, textLength: $0.text.utf8.count)
        }
        let metadataChanged = full || persistedFolders != snapshot.folders || persistedDocuments != documents || persistedIncomplete != snapshot.incomplete

        // Until this save completes, the disk state is unknown.
        needsFullWrite = true
        var groups: [Int: [String: String]] = [:]
        if !dirty.isEmpty {
            for (path, text) in texts {
                let shard = Self.shard(for: path)
                if dirty.contains(shard) { groups[shard, default: [:]][path] = text }
            }
        }
        // Shards first, metadata last: an interrupted save leaves at worst a
        // length mismatch, which load() turns into re-extraction.
        for shard in dirty.sorted() {
            let url = shardURL(shard)
            if let group = groups[shard] { try JSONEncoder().encode(group).write(to: url, options: .atomic) }
            else if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        if metadataChanged {
            let meta = StoredMeta(version: Self.formatVersion, rootPath: snapshot.rootPath, folders: snapshot.folders,
                                  documents: documents, updated: snapshot.updated, incomplete: snapshot.incomplete)
            try JSONEncoder().encode(meta).write(to: file, options: .atomic)
        }
        persistedRoot = snapshot.rootPath
        persistedTexts = texts
        persistedFolders = snapshot.folders
        persistedDocuments = documents
        persistedIncomplete = snapshot.incomplete
        needsFullWrite = false
        lastWrittenShards = dirty.count
        lastWroteMetadata = metadataChanged
    }
}
