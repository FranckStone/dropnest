import XCTest
import SwiftUI
import AppKit
import DropNestCore
@testable import DropNest
@testable import DropNestCore

/// Renders the two windows to PNGs for visual review. Skipped unless
/// `DROPNEST_SNAPSHOT=1` is set, because normal test runs have no need to
/// touch the filesystem with screenshots.
@MainActor
final class VisualSnapshotTests: XCTestCase {
    func testRenderInterfaceSnapshots() throws {
        guard ProcessInfo.processInfo.environment["DROPNEST_SNAPSHOT"] == "1" else {
            throw XCTSkip("Set DROPNEST_SNAPSHOT=1 to render UI snapshots.")
        }
        struct Sample {
            static let root = "/Users/frank/Documents/Archive"
            static let folders = [
                "客户/星河科技/项目文书", "客户/星河科技/合同", "客户/云帆设计/报价",
                "个人/日本行程", "个人/证件", "摄影学习", "财务/发票", "财务/对账单"
            ]
            static let documents = [
                ("客户/星河科技/合同/星河科技-年度服务合同.pdf", "合同约定本年度服务范围与付款节奏。"),
                ("客户/星河科技/项目文书/项目周报-第12周.md", "本周完成登录改版与归档检索验收。"),
                ("个人/日本行程/京都酒店预订.pdf", "入住日期与取消政策。"),
                ("摄影学习/光线笔记.md", "自然光、侧逆光与柔光箱的区别。"),
                ("财务/发票/10月差旅/住宿/酒店发票.pdf", "住宿费发票，价税合计。")
            ]
        }

        let suite = "DropNest-Snapshots-\(UUID())"
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let model = AppModel(dataDirectory: base.appendingPathComponent("state"), defaults: defaults)
        model.config.rootPath = Sample.root
        model.config.useAI = true
        model.config.aiProvider = .compatible
        model.config.rules = [
            SortRule(keyword: "客户A", folder: "客户/客户A"),
            SortRule(keyword: "旅行", folder: "生活/旅行"),
            SortRule(keyword: "发票", folder: "财务/发票")
        ]
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let documents = Sample.documents.enumerated().map { index, item in
            LibraryDocument(
                path: Sample.root + "/" + item.0,
                size: Int64(24_000 + index * 13_000),
                modified: calendar.date(byAdding: .day, value: -index * 3, to: now) ?? now,
                text: item.1,
                textTruncated: false
            )
        }
        let snapshot = LibrarySnapshot(
            rootPath: Sample.root,
            folders: Sample.folders,
            documents: documents,
            updated: now,
            incomplete: false
        )
        model.library = snapshot
        model.monitoringLibrary = true
        model.status = "上次归档：星河科技-年度服务合同.pdf → 客户/星河科技/合同"
        model.duplicateProgress = "找到 2 组重复文件，共 5 份"
        model.duplicateGroups = [
            DuplicateGroup(documents: Array(documents.prefix(2)), contentDigest: Data([1, 2, 3]), stamps: [:]),
            DuplicateGroup(documents: [documents[2], documents[3], documents[1]], contentDigest: Data([4, 5, 6]), stamps: [:])
        ]
        let recordJSON = """
        [
          {"id":"11111111-1111-1111-1111-111111111111","date":\(now.timeIntervalSinceReferenceDate - 3600),
           "source":"/Users/frank/Desktop/星河科技-年度服务合同.pdf",
           "destination":"\(Sample.root)/客户/星河科技/合同/星河科技-年度服务合同.pdf",
           "reason":"AI 选择现有目录：客户/星河科技/合同","status":"moved"},
          {"id":"22222222-2222-2222-2222-222222222222","date":\(now.timeIntervalSinceReferenceDate - 7200),
           "source":"/Users/frank/Desktop/京都酒店.pdf",
           "destination":"\(Sample.root)/个人/日本行程/京都酒店.pdf",
           "reason":"按名称规则：旅行 → 个人/日本行程","status":"moved"},
          {"id":"33333333-3333-3333-3333-333333333333","date":\(now.timeIntervalSinceReferenceDate - 10800),
           "source":"/Users/frank/Desktop/重复报价.pdf",
           "destination":"\(Sample.root)/客户/云帆设计/报价/重复报价.pdf",
           "reason":"内容与已有文件相同，已跳过","status":"duplicate"}
        ]
        """
        model.records = try JSONDecoder().decode([ArchiveRecord].self, from: Data(recordJSON.utf8))
        model.searchQuery = "合同"
        model.searchResults = LibrarySearch.search(snapshot, query: "合同")

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try renderPanel(model: model, output: output)
        for tab in 0...5 {
            model.settingsTab = tab
            try renderSettings(model: model, tab: tab, output: output)
        }
        model.settingsTab = 0
        try renderSettings(model: model, tab: 0, output: output, dark: true)
    }

    private func renderPanel(model: AppModel, output: URL) throws {
        let panel = DropView(model: model)
            .environment(\.colorScheme, .light)
            .padding(24)
            .background {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.35, blue: 0.55),
                                 Color(red: 0.48, green: 0.30, blue: 0.55),
                                 Color(red: 0.92, green: 0.52, blue: 0.36)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Circle().fill(Color.white.opacity(0.18)).frame(width: 130).offset(x: -110, y: -100)
                    Circle().fill(Color.black.opacity(0.10)).frame(width: 90).offset(x: 120, y: 110)
                }
            }
            .frame(width: DropPanelLayout.width + 48, height: DropPanelLayout.height + 48)
        try render(panel, name: "panel-light", output: output)

        let darkPanel = ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.14),
                                    Color(red: 0.14, green: 0.08, blue: 0.17)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.white.opacity(0.08)).frame(width: 150).offset(x: -100, y: -90)
            DropView(model: model).environment(\.colorScheme, .dark).padding(24)
        }
        .frame(width: DropPanelLayout.width + 48, height: DropPanelLayout.height + 48)
        try render(darkPanel, name: "panel-dark", output: output)
    }

    private func renderSettings(model: AppModel, tab: Int, output: URL, dark: Bool = false) throws {
        let view = SettingsView(model: model)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: DropTheme.settingsWidth, height: DropTheme.settingsHeight, alignment: .topLeading)
            .clipped()
        try render(view, name: "settings-\(tab)\(dark ? "-dark" : "")", output: output)
    }

    private func render<V: View>(_ view: V, name: String, output: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            XCTFail("Could not render \(name)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(name)")
            return
        }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
}
