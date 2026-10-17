import SwiftUI
import AppKit
import DropNestCore

private let pine = Color(red: 0.16, green: 0.39, blue: 0.31)
private let muted = Color(red: 0.44, green: 0.48, blue: 0.44)

enum DropPanelLayout {
    static let width: CGFloat = 210
    static let height: CGFloat = 224
}

private struct WindowDragExclusions: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

struct DropView: View {
    @ObservedObject var model: AppModel
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 19)).foregroundStyle(pine)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("落格").font(.system(size: 15, weight: .semibold))
                        Text("DROP NEST").font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(muted)
                    }
                    Spacer()
                    Image(systemName: "circle.grid.2x3.fill").font(.system(size: 11)).foregroundStyle(muted.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                Button(action: model.showSearch) { Image(systemName: "magnifyingglass").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(muted).help("搜索文件名与内容")
                    .anchorPreference(key: WindowDragExclusions.self, value: .bounds) { [$0] }
                Button(action: model.showSettings) { Image(systemName: "slider.horizontal.3").font(.system(size: 15)) }
                    .buttonStyle(.plain).foregroundStyle(muted).help("设置与整理记录")
                    .anchorPreference(key: WindowDragExclusions.self, value: .bounds) { [$0] }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(targeted ? pine.opacity(0.13) : Color.white.opacity(0.65))
                RoundedRectangle(cornerRadius: 14).strokeBorder(pine.opacity(targeted ? 0.8 : 0.24), style: StrokeStyle(lineWidth: 1.3, dash: [5, 5]))
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(pine.opacity(0.08)).frame(width: 42, height: 42)
                        if model.busy { ProgressView().controlSize(.small) }
                        else { Image(systemName: targeted ? "arrow.down.circle.fill" : "tray.and.arrow.down").font(.system(size: 23, weight: .light)).foregroundStyle(pine) }
                    }
                    Text(model.cleaningDuplicates ? "正在清理重复文件" : model.busy ? "正在安放你的文件" : targeted ? "松开，让文件各就各位" : "把文件放进来")
                        .font(.system(size: 13, weight: .medium))
                    Text(model.cleaningDuplicates ? model.duplicateProgress : model.busy ? "队列中还有 \(model.queueCount) 个" : "拖入文件或文件夹")
                        .font(.system(size: 9)).foregroundStyle(muted)
                }.allowsHitTesting(false)
                DropReceiver(onDrop: { model.enqueue($0) }, onHover: { targeted = $0 })
                    .accessibilityLabel("拖入文件或文件夹自动整理")
            }.frame(height: 100)
                .anchorPreference(key: WindowDragExclusions.self, value: .bounds) { [$0] }
            HStack(spacing: 5) {
                Circle().fill(pine).frame(width: 5, height: 5)
                Text(model.config.useAI ? (model.config.aiProvider == .system ? "规则优先 · 本地 AI" : "规则优先 · AI 辅助") : "按规则自动整理").font(.system(size: 9)).foregroundStyle(muted).lineLimit(1)
                Spacer()
                Text("\(model.completedCount) 已归档").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1)
            }
            HStack(alignment: .top, spacing: 5) {
                Text(model.error ?? (model.indexing ? model.indexProgress : model.status)).font(.system(size: 10)).foregroundStyle(model.error == nil ? muted : .red)
                    .lineLimit(2).help(model.error ?? (model.indexing ? model.indexProgress : model.status))
                if model.error != nil {
                    Button { model.error = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.red)
                        .anchorPreference(key: WindowDragExclusions.self, value: .bounds) { [$0] }
                }
            }.frame(height: 24, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: DropPanelLayout.width, height: DropPanelLayout.height)
        .background(Color(red: 0.96, green: 0.965, blue: 0.94))
        .overlayPreferenceValue(WindowDragExclusions.self) { anchors in
            GeometryReader { geometry in
                WindowDragHandle(excludedRects: anchors.map { geometry[$0] })
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.8), lineWidth: 1))
        .environment(\.colorScheme, .light)
    }
}

struct WindowDragHandle: NSViewRepresentable {
    var excludedRects: [CGRect] = []
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) { view.excludedRects = excludedRects }
    final class Handle: NSView {
        var excludedRects: [CGRect] = [] {
            didSet {
                if excludedRects != oldValue { window?.invalidateCursorRects(for: self) }
            }
        }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            super.resetCursorRects()
            var regions = [bounds]
            for excluded in excludedRects {
                regions = regions.flatMap { region -> [CGRect] in
                    let overlap = region.intersection(excluded)
                    guard !overlap.isNull, !overlap.isEmpty else { return [region] }
                    return [
                        CGRect(x: region.minX, y: region.minY, width: region.width, height: overlap.minY - region.minY),
                        CGRect(x: region.minX, y: overlap.maxY, width: region.width, height: region.maxY - overlap.maxY),
                        CGRect(x: region.minX, y: overlap.minY, width: overlap.minX - region.minX, height: overlap.height),
                        CGRect(x: overlap.maxX, y: overlap.minY, width: region.maxX - overlap.maxX, height: overlap.height)
                    ].filter { !$0.isEmpty }
                }
            }
            for region in regions { addCursorRect(region, cursor: .openHand) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            // Let buttons and the file receiver handle their own mouse events.
            guard NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).contains(local),
                  !excludedRects.contains(where: { $0.contains(local) }) else { return nil }
            return self
        }
        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.push()
            defer { NSCursor.pop() }
            window?.performDrag(with: event)
        }
    }
}

struct DropReceiver: NSViewRepresentable {
    var onDrop: ([URL]) -> Void
    var onHover: (Bool) -> Void
    var onClick: (() -> Void)? = nil
    func makeNSView(context: Context) -> Receiver {
        let view = Receiver(); view.registerForDraggedTypes([.fileURL]); updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: Receiver, context: Context) { view.onDrop = onDrop; view.onHover = onHover; view.onClick = onClick }
    final class Receiver: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        var onDrop: ([URL]) -> Void = { _ in }
        var onHover: (Bool) -> Void = { _ in }
        var onClick: (() -> Void)?
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onHover(true); return .move }
        override func draggingExited(_ sender: NSDraggingInfo?) { onHover(false) }
        override func draggingEnded(_ sender: NSDraggingInfo) { onHover(false) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onHover(false)
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }; onDrop(urls); return true
        }
        override func mouseUp(with event: NSEvent) { onClick?() }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("让每份文件，各得其所。").font(.system(size: 24, weight: .semibold))
                    Text("落格 / DROP NEST").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 32, weight: .light)).foregroundStyle(pine)
            }
            Picker("设置页面", selection: $model.settingsTab) {
                Text("归档设置").tag(0); Text("自定义规则").tag(1); Text("搜索文件").tag(2); Text("整理记录").tag(3); Text("重复文件").tag(4); Text("发票整理").tag(5)
            }.pickerStyle(.segmented)
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    Text(error).font(.system(size: 11)).textSelection(.enabled)
                    Spacer(); Button("关闭") { model.error = nil }.buttonStyle(.plain)
                }.padding(12).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }
            Group {
                switch model.settingsTab {
                case 1: RulesView(model: model)
                case 2: LibrarySearchView(model: model)
                case 3: HistoryView(model: model)
                case 4: DuplicateFilesView(model: model)
                case 5: InvoiceImportView(model: model)
                default: GeneralView(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Image(systemName: "lock.shield"); Text("本地索引 · 智能归档 · 支持撤销"); Spacer(); Text("v0.4.1")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(28).frame(width: 780, height: 600)
        .tint(pine)
        .onChange(of: model.config.useAI) { _, _ in model.save() }
    }
}

private struct GeneralView: View {
    @ObservedObject var model: AppModel
    @State private var configureAI = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("归档位置").font(.headline)
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(pine)
                        Text(model.config.rootPath ?? "尚未选择，拖入文件前请先设置").font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button("选择文件夹…", action: model.chooseRoot).disabled(model.busy)
                        if model.root != nil {
                            Button("打开", action: model.openRoot)
                            Button("取消选择", action: model.clearRoot).disabled(model.busy)
                        }
                    }.padding(14).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                    Text("学习这个总目录下的现有文件夹，按内容归档；没有合适目录时自动新建。原有文件只建立搜索索引；拖入的文件夹整体移动。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("启用 AI，按内容细分文档与图片", isOn: $model.config.useAI)
                        Spacer()
                        Button("配置 AI…") { configureAI = true }.disabled(model.busy || model.testingAI)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(pine)
                        Text(model.aiStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("刷新", action: model.refreshAI).font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(pine)
                        if model.config.aiProvider == .compatible {
                            Button(model.testingAI ? "测试中…" : "测试连接", action: model.testAI).font(.system(size: 11)).disabled(model.testingAI || model.busy)
                        }
                    }
                    Text("自定义名称规则优先；其余文件由 AI 按内容优先选择现有目录，没有合适位置时自动创建主题、客户或项目文件夹。新目录会用于后续归档，并纳入搜索。只有线索不足或 AI 不可用时进入“待整理”。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack {
                    Label("仅在桌面显示 · 拖动标题调整位置", systemImage: "desktopcomputer").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("已学习的目录").font(.headline)
                        Spacer()
                        Button("重新整理待整理", action: model.reorganizePending).disabled(model.indexing || model.busy || model.root == nil)
                        Button(model.indexing ? "索引中…" : "刷新目录与索引", action: model.refreshLibrary).disabled(model.indexing || model.busy || model.root == nil)
                    }
                    Text(model.indexing ? model.indexProgress : "\(model.library.folders.count) 个目录 · \(model.library.documents.count) 个文件 · \(model.library.documents.filter { !$0.text.isEmpty }.count) 个文件可搜索内容")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.monitoringLibrary {
                        Text("Finder 中的文件变化会自动更新索引。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if model.busy { Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if model.library.folders.isEmpty && !model.indexing {
                        Text("此处尚无子目录。拖入文件后，AI 会根据内容自动建立合适的文件夹；也可以先在 Finder 中创建你习惯的目录。").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 9) {
                            ForEach(Array(model.library.folders.prefix(12)), id: \.self) { path in
                                Label(path, systemImage: "folder").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(path)
                            }
                        }
                        if model.library.folders.count > 12 { Text("另有 \(model.library.folders.count - 12) 个目录，归档时同样参与判断。").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    if model.library.incomplete {
                        Text("部分目录不可读或已达到索引上限；搜索结果可能不完整。").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
            }.padding(.bottom, 4)
        }
        .sheet(isPresented: $configureAI) { AIConfigurationView(model: model) }
    }
}

private struct AIConfigurationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AIProvider
    @State private var endpoint: String
    @State private var modelName: String
    @State private var allowUpload: Bool
    @State private var key = ""
    init(model: AppModel) {
        self.model = model
        _provider = State(initialValue: model.config.aiProvider)
        _endpoint = State(initialValue: model.config.apiEndpoint)
        _modelName = State(initialValue: model.config.apiModel)
        _allowUpload = State(initialValue: model.config.allowContentUpload && model.config.allowDirectoryContextUpload)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择 AI 来源").font(.title2.bold())
            Picker("来源", selection: $provider) {
                Text("Apple 本地 AI").tag(AIProvider.system)
                Text("兼容 API / Ollama").tag(AIProvider.compatible)
            }.pickerStyle(.segmented)
            if provider == .system {
                Text(SmartClassifier.availability.message).foregroundStyle(.secondary)
                Text("使用系统本地模型，文件名和文字片段不会上传。需要 macOS 26+ 和支持 Apple 智能的 Mac。").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("快速填写：").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("DeepSeek") { endpoint = "https://api.deepseek.com/chat/completions"; modelName = "deepseek-flash"; allowUpload = false }
                    Button("Qwen3.5 9B（本机）") { endpoint = "http://127.0.0.1:11434/v1/chat/completions"; modelName = "qwen3.5:9b"; allowUpload = false }
                }
                LabeledContent("完整接口地址") { TextField("https://…/chat/completions", text: $endpoint) }
                LabeledContent("模型名称") { TextField("填写服务提供的模型 ID", text: $modelName) }
                LabeledContent("API Key") { SecureField("留空沿用已保存的 Key，本机服务可不填", text: $key) }
                Text("密钥仅存入 macOS 钥匙串，不写入配置文件。接口需支持 Chat Completions 和 JSON 输出。").font(.system(size: 11)).foregroundStyle(.secondary)
                if let url = CompatibleAPI.endpoint(endpoint), CompatibleAPI.isLocal(url) {
                    Text("通过本机 Ollama 运行，无需 API Key。请保持 Ollama 运行。若使用会转发到云端的模型，请自行核对服务配置。").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Toggle("允许发送文件名、内容片段、目录线索及发票用途", isOn: $allowUpload)
                    Text("包括现有目录名、代表性文件名、少量正文及本批发票的来源文件夹名称、原子目录和用途说明。完整搜索索引留在本机。云端 API 可能产生费用；不勾选时不发送目录线索和文件内容。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存配置") {
                    if model.saveAI(provider: provider, endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                                    model: modelName.trimmingCharacters(in: .whitespacesAndNewlines), allowUpload: allowUpload, key: key) { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 610).textFieldStyle(.roundedBorder)
        .onChange(of: endpoint) { _, _ in allowUpload = false; key = "" }
    }
}

private struct RulesView: View {
    @ObservedObject var model: AppModel
    @State private var keyword = ""
    @State private var folder = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("名称中包含关键词，就放到指定子目录。规则从上到下匹配，优先于 AI。").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                TextField("关键词，例如：客户A", text: $keyword)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("子目录，例如：工作/客户A", text: $folder)
                Button("添加") {
                    let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                    let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !k.isEmpty, RuleEngine.validateFolder(f) else { model.error = "请填写关键词和有效子目录，例如：工作/客户A。不能使用绝对路径、隐藏目录或 ..。"; return }
                    model.config.rules.append(SortRule(keyword: k, folder: f)); model.save(); keyword = ""; folder = ""
                }.disabled(model.busy)
            }.textFieldStyle(.roundedBorder)
            if model.config.rules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(pine)
                    Text("把你的习惯，交给落格").font(.headline)
                    Text("例如「客户A」→「客户/客户A」，或「旅行」→「生活/旅行」。\n没有自定义规则时，会根据已有目录和文件内容整理。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(model.config.rules.enumerated()), id: \.element.id) { index, rule in
                            HStack {
                                Toggle("", isOn: Binding(get: { model.config.rules.first(where: { $0.id == rule.id })?.enabled ?? false }, set: { enabled in
                                    if let i = model.config.rules.firstIndex(where: { $0.id == rule.id }) { model.config.rules[i].enabled = enabled; model.save() }
                                })).labelsHidden()
                                Text(rule.keyword).frame(width: 150, alignment: .leading)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(rule.folder).foregroundStyle(pine).lineLimit(1)
                                Spacer()
                                Button { model.config.rules.swapAt(index, index - 1); model.save() } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("提高优先级")
                                Button { model.config.rules.removeAll { $0.id == rule.id }; model.save() } label: { Image(systemName: "trash") }.help("删除规则")
                            }.font(.system(size: 12)).padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }.disabled(model.busy)
            }
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("共 \(model.records.count) 条记录 · 显示最近 300 条").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(); Button("打开记录文件夹", action: model.openRecords).font(.system(size: 11))
            }
            if model.records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(pine)
                    Text("每一次整理，都有迹可循").font(.headline)
                    Text("拖入第一份文件后，这里会显示归档位置和撤销入口。").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(model.records.prefix(300))) { record in
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: record.status == .undone ? "arrow.uturn.backward.circle" : record.status == .duplicate ? "doc.on.doc" : "doc").foregroundStyle(pine).font(.system(size: 20))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(record.destination).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(record.destination)
                                    Text("\(label(record)) · \(record.reason) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                    if let detail = record.detail { Text(detail).font(.system(size: 10)).foregroundStyle(.red) }
                                }
                                Spacer()
                                Button { model.reveal(record) } label: { Image(systemName: "magnifyingglass") }.help("在 Finder 中显示")
                                if record.status == .moved { Button("撤销") { model.undo(record) }.disabled(model.busy) }
                            }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }
    private func label(_ record: ArchiveRecord) -> String {
        switch record.status {
        case .moved: "已归档"
        case .undone: "已撤销"
        case .failed: "未完成"
        case .needsReview: "需要核对"
        case .duplicate: "重复，已跳过"
        case .unchanged: "位置已正确"
        case .planned, .undoing: "操作中"
        }
    }
}
