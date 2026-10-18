import Foundation

public enum FileCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case contracts, receipts, resumes, learning, images, videos, audio, archives, code, documents, folders, pending
    public var id: String { rawValue }
    public var path: String {
        switch self {
        case .contracts: "工作/合同"
        case .receipts: "工作/票据"
        case .resumes: "工作/简历"
        case .learning: "学习/资料"
        case .images: "图片"
        case .videos: "视频"
        case .audio: "音频"
        case .archives: "压缩包"
        case .code: "代码"
        case .documents: "文档"
        case .folders: "文件夹"
        case .pending: "待整理"
        }
    }
    public var symbol: String {
        switch self {
        case .contracts: "signature"
        case .receipts: "receipt"
        case .resumes: "person.text.rectangle"
        case .learning: "book.closed"
        case .images: "photo"
        case .videos: "film"
        case .audio: "waveform"
        case .archives: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .documents: "doc.text"
        case .folders: "folder"
        case .pending: "tray"
        }
    }
}

public struct SortRule: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var keyword: String
    public var folder: String
    public var enabled: Bool = true
    public init(keyword: String, folder: String, enabled: Bool = true) {
        self.keyword = keyword; self.folder = folder; self.enabled = enabled
    }
}

public struct Configuration: Codable, Sendable {
    public var rootPath: String?
    public var useAI = true
    public var rules: [SortRule] = []
    public var aiProvider = AIProvider.compatible
    public var apiEndpoint = "http://127.0.0.1:11434/v1/chat/completions"
    public var apiModel = "qwen3.5:9b"
    public var allowContentUpload = false
    public var allowDirectoryContextUpload = false
    public var folderDropMode = FolderDropMode.ask
    public init() {}
    enum CodingKeys: String, CodingKey { case rootPath, useAI, rules, aiProvider, apiEndpoint, apiModel, allowContentUpload, allowDirectoryContextUpload, folderDropMode }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try c.decodeIfPresent(String.self, forKey: .rootPath)
        useAI = try c.decodeIfPresent(Bool.self, forKey: .useAI) ?? true
        rules = try c.decodeIfPresent([SortRule].self, forKey: .rules) ?? []
        aiProvider = try c.decodeIfPresent(AIProvider.self, forKey: .aiProvider) ?? .compatible
        apiEndpoint = try c.decodeIfPresent(String.self, forKey: .apiEndpoint) ?? apiEndpoint
        apiModel = try c.decodeIfPresent(String.self, forKey: .apiModel) ?? apiModel
        allowContentUpload = try c.decodeIfPresent(Bool.self, forKey: .allowContentUpload) ?? false
        allowDirectoryContextUpload = try c.decodeIfPresent(Bool.self, forKey: .allowDirectoryContextUpload) ?? false
        folderDropMode = (try? c.decodeIfPresent(FolderDropMode.self, forKey: .folderDropMode)) ?? .ask
    }
}

/// How a dropped folder is archived: moved as one item, or split so every
/// file inside is classified on its own.
public enum FolderDropMode: String, Codable, Sendable, CaseIterable {
    case ask, whole, split
    public var title: String {
        switch self {
        case .ask: "每次询问"
        case .whole: "整体归档"
        case .split: "拆分逐个归档"
        }
    }
}

public enum AIProvider: String, Codable, Sendable { case system, compatible }

public enum CompatibleAPI {
    public static func endpoint(_ string: String) -> URL? {
        guard let url = URL(string: string), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasSuffix("/chat/completions") else { return nil }
        if url.scheme == "https" { return url }
        if url.scheme == "http", isLocal(url) { return url }
        return nil
    }
    public static func isLocal(_ url: URL) -> Bool { ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? "") }
    public static func decodeDecision(_ data: Data) throws -> Decision {
        struct Result: Decodable { let category: String; let confident: Bool }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard let category = FileCategory(rawValue: result.category),
              [.contracts, .receipts, .resumes, .learning, .images, .documents, .pending].contains(category) else {
            throw ArchiveError.invalid("模型返回了无效分类。")
        }
        let chosen: FileCategory = result.confident ? category : .pending
        return Decision(folder: chosen.path, reason: chosen == .pending ? "AI 接口：证据不足，留待整理" : "AI 接口：\(chosen.path)")
    }
}

public struct Decision: Sendable {
    public let folder: String
    public let reason: String
    public let requiresExistingFolder: Bool
    public init(folder: String, reason: String, requiresExistingFolder: Bool = false) {
        self.folder = folder; self.reason = reason; self.requiresExistingFolder = requiresExistingFolder
    }
}

public enum RuleEngine {
    public static func validateFolder(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }

    public static func customDecision(for url: URL, rules: [SortRule]) -> Decision? {
        for rule in rules where rule.enabled && !rule.keyword.trimmingCharacters(in: .whitespaces).isEmpty {
            if validateFolder(rule.folder), url.lastPathComponent.localizedCaseInsensitiveContains(rule.keyword) {
                return Decision(folder: rule.folder, reason: "名称规则：\(rule.keyword)")
            }
        }
        return nil
    }

    public static func fallback(for url: URL, isDirectory: Bool) -> Decision {
        let ext = url.pathExtension.lowercased()
        let category: FileCategory
        if isDirectory { category = .folders }
        else if ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg", "raw", "avif"].contains(ext) { category = .images }
        else if ["mp4", "mov", "mkv", "avi", "webm", "m4v"].contains(ext) { category = .videos }
        else if ["mp3", "wav", "aac", "flac", "m4a", "aiff", "ogg"].contains(ext) { category = .audio }
        else if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso"].contains(ext) { category = .archives }
        else if ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "c", "cpp", "h", "html", "css", "json", "yaml", "yml", "sh", "sql"].contains(ext) { category = .code }
        else if ["pdf", "txt", "md", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "pages", "numbers", "key"].contains(ext) { category = .documents }
        else { category = .pending }
        return Decision(folder: category.path, reason: category == .pending ? "未识别类型，留待整理" : "类型规则：\(isDirectory ? "文件夹" : ext.uppercased())")
    }
}
