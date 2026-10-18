import Foundation
import DropNestCore

actor LibraryWorker {
    private var store: LibraryStore
    private var snapshot = LibrarySnapshot()
    private var searchIndex: LibrarySearchIndex?
    private var loaded = false
    /// Reading the stored index is deferred to the first rebuild or search so
    /// it never runs on the caller's (main) thread.
    init(storage: URL) {
        store = LibraryStore(file: storage)
    }
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        snapshot = store.load()
    }
    func rebuild(root: URL, progress: @Sendable (Int, Int) async -> Void) async throws -> LibrarySnapshot {
        ensureLoaded()
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
        try store.save(next)
        searchIndex = LibrarySearchIndex(next, reusing: searchIndex)
        snapshot = next
        return next
    }
    func search(query: String, root: String) -> [LibrarySearchHit] {
        ensureLoaded()
        guard snapshot.rootPath == root else { return [] }
        if searchIndex == nil { searchIndex = LibrarySearchIndex(snapshot) }
        return LibrarySearch.search(searchIndex!, query: query)
    }
    /// Shards rewritten by the most recent rebuild; exposed for tests.
    var lastWrittenShards: Int { store.lastWrittenShards }
}
