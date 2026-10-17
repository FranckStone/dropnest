import Foundation
import DropNestCore

actor LibraryWorker {
    private struct StoredIndex: Codable {
        let version: Int
        let snapshot: LibrarySnapshot
    }
    private static let formatVersion = 1
    private let storage: URL
    private var snapshot = LibrarySnapshot()
    init(storage: URL) {
        self.storage = storage
        if let data = try? Data(contentsOf: storage), let decoded = try? JSONDecoder().decode(StoredIndex.self, from: data), decoded.version == Self.formatVersion {
            snapshot = decoded.snapshot
        }
    }
    func rebuild(root: URL, progress: @Sendable (Int, Int) async -> Void) async throws -> LibrarySnapshot {
        var next = try LibraryScanner.scan(root: root)
        let previous = snapshot.rootPath == next.rootPath ? Dictionary(uniqueKeysWithValues: snapshot.documents.map { ($0.path, $0) }) : [:]
        var remainingCharacters = 12_000_000
        for index in next.documents.indices {
            try Task.checkCancellation()
            let file = next.documents[index]
            if let old = previous[file.path], old.modified == file.modified, old.size == file.size, old.text.count <= remainingCharacters {
                next.documents[index] = old; remainingCharacters -= old.text.count
            } else if remainingCharacters > 0 {
                let text = FileTextExtractor.extract(root.appendingPathComponent(file.path), limit: min(60_000, remainingCharacters))
                next.documents[index].text = text.text
                next.documents[index].textTruncated = text.truncated
                remainingCharacters -= text.text.count
            } else { next.documents[index].textTruncated = true; next.incomplete = true }
            if index % 10 == 0 { await progress(index + 1, next.documents.count) }
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(StoredIndex(version: Self.formatVersion, snapshot: next)).write(to: storage, options: .atomic)
        snapshot = next
        return next
    }
    func search(query: String, root: String) -> [LibrarySearchHit] {
        guard snapshot.rootPath == root else { return [] }
        return LibrarySearch.search(snapshot, query: query)
    }
}
