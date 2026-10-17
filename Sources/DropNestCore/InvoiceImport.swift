import Foundation

public struct InvoiceImportItem: Sendable {
    public let url: URL
    public let relativeFolder: String
    public let stamp: FileStamp
}

public struct InvoiceBatch: Sendable {
    public let sourceFolder: URL
    public let items: [InvoiceImportItem]
    public let unsupportedCount: Int
    public static let defaultCategories = ["交通", "住宿", "餐饮", "办公用品", "加油", "通讯", "服务", "设备", "材料"]
    private static let supported: Set<String> = ["pdf", "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp", "bmp", "txt", "xml", "csv", "rtf", "doc", "docx"]

    public static func scan(folder: URL, archiveRoot: URL) throws -> InvoiceBatch {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        let archive = archiveRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard folder != archive, !archive.path.hasPrefix(folder.path + "/") else {
            throw ArchiveError.invalid("请选择单独的发票文件夹，不能选择归档总目录或包含它的上级目录。")
        }
        guard try folder.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]).isDirectory == true,
              try folder.resourceValues(forKeys: [.isPackageKey]).isPackage != true,
              InvoiceRouting.validComponent(folder.lastPathComponent, maxLength: 255) else {
            throw ArchiveError.invalid("请选择有效的发票文件夹，名称不能包含隐藏目录、反斜杠或控制字符。")
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else {
            throw ArchiveError.invalid("无法读取发票文件夹。")
        }
        var items: [InvoiceImportItem] = []
        var unsupported = 0
        var count = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            guard count <= 20_000 else { throw ArchiveError.invalid("发票文件夹超过 20,000 个条目，请分批导入。") }
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if values.isPackage == true || url.lastPathComponent == "node_modules" { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard supported.contains(url.pathExtension.lowercased()) else { unsupported += 1; continue }
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard normalized.path.hasPrefix(folder.path + "/") else { throw ArchiveError.invalid("发票来源目录发生变化，请重新选择。") }
            let relative = String(normalized.path.dropFirst(folder.path.count + 1))
            let parent = relative.split(separator: "/").dropLast().joined(separator: "/")
            items.append(InvoiceImportItem(url: normalized, relativeFolder: parent, stamp: try FileStamp.read(normalized)))
        }
        if let scanError { throw scanError }
        return InvoiceBatch(sourceFolder: folder, items: items.sorted { $0.url.path < $1.url.path }, unsupportedCount: unsupported)
    }
}

public struct InvoiceContext: Sendable {
    public let sourceFolder: URL
    public let relativeFolder: String
    public let purpose: String
    public let categories: [String]
    public let originalFiles: Set<URL>
    public init(sourceFolder: URL, relativeFolder: String, purpose: String, categories: [String], originalFiles: Set<URL> = []) throws {
        let purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard purpose.isEmpty || InvoiceRouting.validComponent(purpose),
              InvoiceRouting.validComponent(sourceFolder.lastPathComponent, maxLength: 255),
              !categories.isEmpty, categories.count <= 24,
              categories.allSatisfy({ InvoiceRouting.validComponent($0) }), Set(categories).count == categories.count else {
            throw ArchiveError.invalid("用途和类型请填写单层名称，每项最多40字，不能包含斜杠、隐藏目录或控制字符；类型为1至24项且不能重复。")
        }
        self.sourceFolder = sourceFolder; self.relativeFolder = relativeFolder
        self.purpose = purpose; self.categories = categories
        self.originalFiles = originalFiles
    }
}

public enum InvoiceRouting {
    public static func validComponent(_ name: String, maxLength: Int = 40) -> Bool {
        name.count <= maxLength && name.utf8.count <= 255 && !name.contains("/") && RuleEngine.validateFolder(name)
    }
    public static func decode(_ data: Data, context: InvoiceContext) throws -> Decision? {
        struct Reply: Decodable {
            let is_invoice: Bool
            let purpose: String
            let purpose_confident: Bool
            let category_id: Int
            let confident: Bool
            let reason: String
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.is_invoice else { return nil }
        guard reply.category_id == -1 || context.categories.indices.contains(reply.category_id) else {
            throw ArchiveError.invalid("发票类型不在本次允许的类型中，文件保留原处。")
        }
        let purpose: String
        if !context.purpose.isEmpty { purpose = context.purpose }
        else if reply.purpose_confident {
            let proposed = reply.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validComponent(proposed) else { throw ArchiveError.invalid("发票用途名称无效，文件保留原处。") }
            purpose = proposed
        } else { purpose = "用途待确认" }
        let category = reply.confident && reply.category_id >= 0 ? context.categories[reply.category_id] : "分类待确认"
        return Decision(folder: "\(context.sourceFolder.lastPathComponent)/\(purpose)/\(category)",
            reason: "发票用途：\(purpose) · 类型：\(category) · \(String(reply.reason.prefix(80)))")
    }
}
