import Foundation

public enum ArchiveError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}

public struct FileStamp: Codable, Equatable, Sendable {
    public let inode: UInt64
    public let device: UInt64
    public let size: UInt64
    public let modified: Date
    public static func read(_ url: URL) throws -> FileStamp {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileStamp(inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                         device: (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                         size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                         modified: attrs[.modificationDate] as? Date ?? .distantPast)
    }
}

public struct ArchiveRecord: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case planned, moved, undoing, undone, failed, needsReview, duplicate, unchanged }
    public var id = UUID()
    public var date = Date()
    public let source: String
    public let destination: String
    public let reason: String
    public var status: Status = .planned
    public var stamp: FileStamp?
    public var detail: String?
    public var name: String { URL(fileURLWithPath: source).lastPathComponent }
}

/// All mutations are serialized by the caller (the application's ArchiveWorker actor).
public final class ArchiveJournal {
    private let file: URL
    private let fm = FileManager.default
    public private(set) var records: [ArchiveRecord]

    public init(file: URL) throws {
        self.file = file
        if fm.fileExists(atPath: file.path) {
            records = try JSONDecoder().decode([ArchiveRecord].self, from: Data(contentsOf: file))
        } else { records = [] }
        var changed = false
        for index in records.indices where records[index].status == .planned || records[index].status == .undoing {
            let sourceExists = fm.fileExists(atPath: records[index].source)
            let target = URL(fileURLWithPath: records[index].destination)
            let targetExists = fm.fileExists(atPath: target.path)
            if records[index].status == .undoing, sourceExists && !targetExists {
                records[index].status = .undone
            } else if targetExists && !sourceExists {
                // An interrupted move cannot be proven to own this destination. Never auto-undo it.
                records[index].status = .needsReview
                records[index].detail = "上次操作中断，请在 Finder 核对原位置与归档位置。"
            } else if sourceExists && !targetExists {
                records[index].status = .failed
                records[index].detail = "上次操作中断，文件仍在原位置。"
            } else {
                records[index].status = .needsReview
                records[index].detail = "上次操作中断，文件状态需要在 Finder 核对。"
            }
            changed = true
        }
        if changed { try save() }
    }

    private func save() throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: file, options: .atomic)
    }

    private func contains(_ child: URL, in parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }

    public func archive(source: URL, root: URL, decision: Decision) throws -> ArchiveRecord {
        try move(source: source, root: root, decision: decision, fromPending: false)
    }

    public func archivePending(source: URL, root: URL, decision: Decision) throws -> ArchiveRecord {
        try move(source: source, root: root, decision: decision, fromPending: true)
    }

    public func archiveInvoice(source: URL, root: URL, decision: Decision, sourceFolder: URL,
                               expectedStamp: FileStamp? = nil, originalFiles: Set<URL> = []) throws -> ArchiveRecord {
        try move(source: source, root: root, decision: decision, fromPending: false, invoiceSource: sourceFolder,
                 expectedStamp: expectedStamp, originalFiles: originalFiles)
    }

    private func move(source: URL, root: URL, decision: Decision, fromPending: Bool, invoiceSource: URL? = nil,
                      expectedStamp: FileStamp? = nil, originalFiles: Set<URL> = []) throws -> ArchiveRecord {
        guard RuleEngine.validateFolder(decision.folder) else { throw ArchiveError.invalid("目标子文件夹无效。") }
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw ArchiveError.invalid("暂不整理符号链接，请拖入原文件。") }
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        if let expectedStamp, try FileStamp.read(source) != expectedStamp {
            throw ArchiveError.invalid("发票在扫描或分类后发生变化，已保留原处，请重新扫描。")
        }
        guard !contains(root, in: source) else {
            throw ArchiveError.invalid("不能移动包含归档目录的文件夹。")
        }
        if let invoiceSource {
            let scope = invoiceSource.standardizedFileURL.resolvingSymlinksInPath()
            guard !contains(root, in: scope), source != scope, contains(source, in: scope), values.isDirectory != true,
                  decision.folder.hasPrefix(scope.lastPathComponent + "/") else {
                throw ArchiveError.invalid("只能在所选发票文件夹范围内逐份整理，目标必须保留来源文件夹归属。")
            }
            if source.deletingLastPathComponent() == root.appendingPathComponent(decision.folder).resolvingSymlinksInPath() {
                return ArchiveRecord(source: source.path, destination: source.path, reason: "已在对应的发票用途和类型目录中", status: .unchanged)
            }
        } else if fromPending {
            let pending = root.appendingPathComponent("待整理", isDirectory: true)
            let destination = root.appendingPathComponent(decision.folder).resolvingSymlinksInPath()
            guard pending.resolvingSymlinksInPath().path == pending.path,
                  source.deletingLastPathComponent().path == pending.path,
                  !contains(destination, in: pending) else {
                throw ArchiveError.invalid("只能重新整理待整理中的直接子项，目标必须位于待整理之外。")
            }
        } else if contains(source, in: root) {
            throw ArchiveError.invalid("文件已在归档目录中，或包含归档目录，已跳过。")
        }
        guard !contains(file.standardizedFileURL.resolvingSymlinksInPath(), in: source) else {
            throw ArchiveError.invalid("不能移动落格自己的记录目录。")
        }
        if let existing = try DuplicateFiles.match(source: source, root: root,
            excludingOriginals: invoiceSource == nil ? [] : originalFiles,
            destinationFolder: invoiceSource == nil ? nil : root.appendingPathComponent(decision.folder).resolvingSymlinksInPath()) {
            if let expectedStamp, try FileStamp.read(source) != expectedStamp {
                throw ArchiveError.invalid("发票在重复检查期间发生变化，已保留原处。")
            }
            let record = ArchiveRecord(source: source.path, destination: existing.path,
                reason: "与已有文件内容完全相同，原文件保留在原位置", status: .duplicate)
            records.insert(record, at: 0)
            do { try save() } catch { records.removeFirst(); throw error }
            return record
        }
        var folder = root
        if decision.requiresExistingFolder {
            let existing = root.appendingPathComponent(decision.folder).resolvingSymlinksInPath()
            guard contains(existing, in: root),
                  (try? existing.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw ArchiveError.invalid("AI 选择的已有目录已不存在，请刷新目录后重试。")
            }
        }
        if !decision.requiresExistingFolder { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        // Validate every component before creation so existing symlinks cannot escape the root.
        for part in decision.folder.split(separator: "/") {
            folder.appendPathComponent(String(part), isDirectory: true)
            guard contains(folder.resolvingSymlinksInPath(), in: root) else {
                throw ArchiveError.invalid("归档子目录指向外部位置，已停止。")
            }
            if decision.requiresExistingFolder {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    throw ArchiveError.invalid("已有目录在归档前发生变化，请刷新目录后重试。")
                }
            } else { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        }
        var target = folder.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while fm.fileExists(atPath: target.path) {
            let ext = source.pathExtension
            let stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
            target = folder.appendingPathComponent("\(stem) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)"))
            suffix += 1
        }
        var record = ArchiveRecord(source: source.path, destination: target.path, reason: decision.reason)
        records.insert(record, at: 0)
        do { try save() } catch { records.removeFirst(); throw error }
        do {
            // FileManager refuses to overwrite an existing destination, including a racing writer.
            if let expectedStamp, try FileStamp.read(source) != expectedStamp {
                throw ArchiveError.invalid("发票在分类后发生变化，已保留原处，请重新扫描。")
            }
            try fm.moveItem(at: source, to: target)
        } catch {
            records[0].status = .failed; records[0].detail = error.localizedDescription
            try save()
            throw error
        }
        record.status = .moved
        record.stamp = try? FileStamp.read(target)
        records[0] = record
        try save()
        return record
    }

    public func undo(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].status == .moved else {
            throw ArchiveError.invalid("此记录不能撤销。")
        }
        let source = URL(fileURLWithPath: records[index].source)
        let destination = URL(fileURLWithPath: records[index].destination)
        guard source.resolvingSymlinksInPath().path == source.path else {
            throw ArchiveError.invalid("原位置的父目录已被替换为链接，请在 Finder 中手动恢复。")
        }
        guard !fm.fileExists(atPath: source.path) else { throw ArchiveError.invalid("原位置已有同名文件，撤销已停止，避免覆盖。") }
        guard let stamp = records[index].stamp, try FileStamp.read(destination) == stamp else {
            throw ArchiveError.invalid("归档文件已发生变化，请在 Finder 中手动恢复。")
        }
        records[index].status = .undoing
        try save()
        do { try fm.moveItem(at: destination, to: source) }
        catch {
            records[index].status = .moved
            try save()
            throw error
        }
        records[index].status = .undone
        try save()
    }
}
