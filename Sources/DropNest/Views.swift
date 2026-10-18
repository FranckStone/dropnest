import SwiftUI
import AppKit
import DropNestCore

enum DropPanelLayout {
    static let width: CGFloat = 210
    static let height: CGFloat = 160
    static let cornerRadius: CGFloat = DropTheme.panelRadius
}

private struct WindowDragExclusions: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Desktop panel

struct DropView: View {
    @ObservedObject var model: AppModel
    @State private var targeted = false

    private var dropTitle: String {
        if model.cleaningDuplicates { return "正在清理重复" }
        if model.busy { return "正在安放文件" }
        if targeted { return "松开，各就各位" }
        return "把文件放进来"
    }

    private var dropDetail: String {
        if model.cleaningDuplicates { return model.duplicateProgress }
        if model.busy { return "队列中还有 \(model.queueCount) 份" }
        if targeted { return "自动读取内容并归档" }
        return "拖入文件或文件夹"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            dropZone.padding(.top, 9)
        }
        .padding(.horizontal, 11)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .frame(width: DropPanelLayout.width, height: DropPanelLayout.height, alignment: .top)
        .background { GlassPanelBackground() }
        .clipShape(RoundedRectangle(cornerRadius: DropPanelLayout.cornerRadius, style: .continuous))
        .overlay { GlassEdge() }
        .overlayPreferenceValue(WindowDragExclusions.self) { anchors in
            if !DropSnapshotMode.enabled {
                GeometryReader { geometry in
                    WindowDragHandle(excludedRects: anchors.map { geometry[$0] })
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            NestMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("落格").font(.system(size: 14, weight: .semibold))
                Text(model.config.useAI ? "智能归档" : "规则归档")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            GlassIconButton(systemImage: "magnifyingglass", help: "搜索文件名与内容", action: model.showSearch)
                .anchorPreference(key: WindowDragExclusions.self, value: .bounds) { [$0] }
            GlassIconButton(systemImage: "slider.horizontal.3", help: "设置与整理记录", action: model.showSettings)
                .anchorPreference(key: WindowDragExclusions.self, value: .bounds) { [$0] }
        }
        .frame(height: 30)
    }

    private var dropZone: some View {
        ZStack {
            DropWellBackground(targeted: targeted, cornerRadius: 18)
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(DropTheme.accent.opacity(0.11)).frame(width: 42, height: 42)
                    Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1).frame(width: 42, height: 42)
                    if model.busy {
                        ProgressView().controlSize(.small).tint(DropTheme.accent)
                    } else {
                        Image(systemName: targeted ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                            .font(.system(size: 22, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(DropTheme.accent)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                VStack(spacing: 2) {
                    Text(dropTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                    Text(dropDetail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .allowsHitTesting(false)
            if DropSnapshotMode.enabled {
                Color.clear
            } else {
                DropReceiver(onDrop: { model.enqueue($0) }, onHover: { targeted = $0 })
                    .accessibilityLabel("拖入文件或文件夹自动整理")
            }
        }
        .frame(height: 100)
        .scaleEffect(targeted ? 1.012 : 1, anchor: .center)
        .animation(.smooth(duration: 0.22), value: targeted)
        .anchorPreference(key: WindowDragExclusions.self, value: .bounds) { [$0] }
    }
}

private struct NestMark: View {
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(DropTheme.accentGradient)
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: Color.black.opacity(0.22), radius: 1.5, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: DropTheme.accent.opacity(0.28), radius: 5, y: 2)
        .accessibilityHidden(true)
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
            guard NSBezierPath(roundedRect: bounds, xRadius: DropPanelLayout.cornerRadius,
                               yRadius: DropPanelLayout.cornerRadius).contains(local),
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

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if DropSnapshotMode.enabled {
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 0) {
                        SettingsSidebar(model: model)
                            .frame(width: DropTheme.sidebarWidth, height: geometry.size.height)
                            .background(.thinMaterial)
                        Rectangle().fill(DropTheme.border).frame(width: 1, height: geometry.size.height)
                        SettingsDetail(model: model)
                            .frame(width: geometry.size.width - DropTheme.sidebarWidth - 1,
                                   height: geometry.size.height, alignment: .top)
                            .clipped()
                    }
                }
            } else {
                NavigationSplitView {
                    SettingsSidebar(model: model)
                        .navigationSplitViewColumnWidth(min: 196, ideal: DropTheme.sidebarWidth, max: 244)
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    SettingsDetail(model: model)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .frame(minWidth: DropTheme.settingsMinWidth, minHeight: DropTheme.settingsMinHeight)
        .tint(DropTheme.accent)
        .onChange(of: model.config.useAI) { _, _ in model.save() }
    }
}

/// Custom sidebar instead of `List(.sidebar)`: the native selection always
/// uses the system accent (blue), which clashes with the jade theme.
private struct SettingsSidebar: View {
    @ObservedObject var model: AppModel

    private struct Item: Identifiable {
        let id: Int
        let title: String
        let icon: String
    }

    private let groups: [(String, [Item])] = [
        ("归档", [Item(id: 0, title: "归档设置", icon: "square.grid.2x2"),
                Item(id: 1, title: "自定义规则", icon: "line.3.horizontal.decrease.circle")]),
        ("内容与工具", [Item(id: 2, title: "搜索文件", icon: "magnifyingglass"),
                    Item(id: 3, title: "整理记录", icon: "clock.arrow.circlepath"),
                    Item(id: 4, title: "重复文件", icon: "doc.on.doc"),
                    Item(id: 5, title: "发票整理", icon: "banknote")])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                NestMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("落格").font(.system(size: 14, weight: .semibold))
                    Text("DROP NEST")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, DropSnapshotMode.enabled ? 40 : 8)
            .padding(.bottom, 14)

            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Text(group.0)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ForEach(group.1) { item in
                    SidebarRow(title: item.title, icon: item.icon, selected: model.settingsTab == item.id) {
                        model.settingsTab = item.id
                    }
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Label("本地索引 · 支持撤销", systemImage: "lock.shield")
                    .font(.system(size: 10))
                Text("v\(DropTheme.version)")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? DropTheme.accent : Color.secondary)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                selected ? DropTheme.accent.opacity(0.14) : Color.primary.opacity(hovering ? 0.05 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SettingsDetail: View {
    @ObservedObject var model: AppModel

    private var page: (title: String, subtitle: String) {
        switch model.settingsTab {
        case 1: ("自定义规则", "用名称关键词决定文件去向")
        case 2: ("搜索文件", "文件名、路径与可提取的正文")
        case 3: ("整理记录", "每一次移动都有迹可循，可撤销")
        case 4: ("重复文件", "找出内容完全相同的副本")
        case 5: ("发票整理", "按来源、用途与类型批量归档")
        default: ("归档设置", "归档位置、AI 与本地索引")
        }
    }

    var body: some View {
        Group {
            if DropSnapshotMode.enabled {
                scrollContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(detailBackground)
            } else {
                ScrollView { scrollContent }
                    .background(detailBackground)
            }
        }
    }

    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPageHeader(title: page.title, subtitle: page.subtitle)
            if let error = model.error {
                ErrorBanner(message: error) { model.error = nil }
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
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 32)
        .padding(.top, DropSnapshotMode.enabled ? 40 : 14)
        .padding(.bottom, 32)
        // Keep line length readable when the window is maximized.
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var detailBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [DropTheme.accent.opacity(0.055), .clear],
                           startPoint: .topLeading, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

private struct ErrorBanner: View {
    let message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭")
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: DropTheme.rowRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DropTheme.rowRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }
}

// MARK: - General

private struct GeneralView: View {
    @ObservedObject var model: AppModel
    @State private var configureAI = false

    private var folderName: String {
        model.config.rootPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "尚未选择归档总目录"
    }

    private var searchableCount: Int {
        model.library.documents.filter { !$0.text.isEmpty }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard("归档位置", systemImage: "folder") {
                InsetRow {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(DropTheme.accent.opacity(0.12))
                                .frame(width: 36, height: 36)
                            Image(systemName: "folder.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(DropTheme.accent)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(folderName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                            if let path = model.config.rootPath {
                                Text(path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                            } else {
                                Text("选择后只读取现有目录，不会搬动原有文件")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("选择…", action: model.chooseRoot)
                            .disabled(model.busy)
                    }
                }
                HStack(spacing: 8) {
                    Button("在 Finder 中打开", action: model.openRoot)
                        .disabled(model.root == nil)
                    Button("取消选择", role: .destructive, action: model.clearRoot)
                        .disabled(model.busy || model.root == nil)
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("学习这个总目录下的现有文件夹，按内容归档；没有合适目录时自动新建。原有文件只建立搜索索引；拖入的文件夹整体移动。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard("智能归档", systemImage: "sparkles") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("按内容细分文档与图片").font(.system(size: 13))
                        Text("关闭后只按自定义规则归档，其余进入“待整理”")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("按内容细分文档与图片", isOn: $model.config.useAI)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                InsetRow {
                    HStack(spacing: 9) {
                        StatusDot(active: model.config.useAI)
                        Text(model.aiStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(model.aiStatus)
                        Spacer(minLength: 8)
                        Button(action: model.refreshAI) { Image(systemName: "arrow.clockwise") }
                            .help("刷新 AI 状态")
                            .accessibilityLabel("刷新 AI 状态")
                        if model.config.aiProvider == .compatible {
                            Button(model.testingAI ? "测试中…" : "测试连接", action: model.testAI)
                                .disabled(model.testingAI || model.busy)
                        }
                        Button("配置 AI…") { configureAI = true }
                            .disabled(model.busy || model.testingAI)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text("自定义名称规则优先；其余文件由 AI 按内容优先选择现有目录，没有合适位置时自动创建主题、客户或项目文件夹。新目录会用于后续归档，并纳入搜索。只有线索不足或 AI 不可用时进入“待整理”。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard("目录与索引", systemImage: "square.stack.3d.up") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(model.library.folders.count) 个目录 · \(model.library.documents.count) 个文件 · \(searchableCount) 个可搜索")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                        Text(model.indexing ? model.indexProgress : (model.monitoringLibrary ? "Finder 中的变化会自动更新索引" : "索引未在监听"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if model.busy {
                            Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("重新整理待整理", action: model.reorganizePending)
                        .disabled(model.indexing || model.busy || model.root == nil)
                    Button(model.indexing ? "索引中…" : "刷新索引", action: model.refreshLibrary)
                        .disabled(model.indexing || model.busy || model.root == nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if model.library.folders.isEmpty && !model.indexing {
                    Text("此处尚无子目录。拖入文件后，AI 会根据内容自动建立合适的文件夹；也可以先在 Finder 中创建你习惯的目录。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 7) {
                        ForEach(Array(model.library.folders.prefix(12)), id: \.self) { path in
                            HStack(spacing: 5) {
                                Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(DropTheme.accent)
                                Text(path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DropTheme.rowFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .help(path)
                        }
                    }
                    if model.library.folders.count > 12 {
                        Text("另有 \(model.library.folders.count - 12) 个目录，归档时同样参与判断。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                if model.library.incomplete {
                    Label("部分目录不可读或已达到索引上限；搜索结果可能不完整。", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            SettingsCard("窗口与启动", systemImage: "desktopcomputer") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录时启动").font(.system(size: 13))
                        Text("仅在桌面显示，按住面板任意空白处即可拖动")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
        .sheet(isPresented: $configureAI) { AIConfigurationView(model: model) }
    }
}

// MARK: - AI configuration

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
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(DropTheme.accent.opacity(0.12)).frame(width: 38, height: 38)
                    Image(systemName: "sparkles").font(.system(size: 16, weight: .medium)).foregroundStyle(DropTheme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("选择 AI 来源").font(.system(size: 17, weight: .semibold))
                    Text("判断目录与细分内容，始终由你决定是否发送线索。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("来源", selection: $provider) {
                Text("Apple 本地 AI").tag(AIProvider.system)
                Text("兼容 API / Ollama").tag(AIProvider.compatible)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if provider == .system {
                SettingsCard("系统模型", systemImage: "sparkles") {
                    Text(SmartClassifier.availability.message)
                        .font(.system(size: 12))
                    Text("使用系统本地模型，文件名和文字片段不会上传。需要 macOS 26+ 和支持 Apple 智能的 Mac。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SettingsCard("连接", systemImage: "network") {
                    HStack(spacing: 6) {
                        Text("快速填写").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("DeepSeek") {
                            endpoint = "https://api.deepseek.com/chat/completions"; modelName = "deepseek-flash"; allowUpload = false
                        }
                        Button("Qwen3.5 9B（本机）") {
                            endpoint = "http://127.0.0.1:11434/v1/chat/completions"; modelName = "qwen3.5:9b"; allowUpload = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    LabeledContent("完整接口地址") {
                        TextField("https://…/chat/completions", text: $endpoint)
                    }
                    LabeledContent("模型名称") {
                        TextField("填写服务提供的模型 ID", text: $modelName)
                    }
                    LabeledContent("API Key") {
                        SecureField("留空沿用已保存的 Key，本机服务可不填", text: $key)
                    }
                    Text("密钥仅存入 macOS 钥匙串，不写入配置文件。接口需支持 Chat Completions 和 JSON 输出。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let url = CompatibleAPI.endpoint(endpoint), CompatibleAPI.isLocal(url) {
                    Label("通过本机 Ollama 运行，无需 API Key。请保持 Ollama 运行；若使用会转发到云端的模型，请自行核对服务配置。", systemImage: "desktopcomputer")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    SettingsCard("隐私", systemImage: "lock.shield") {
                        Toggle("允许发送文件名、内容片段、目录线索及发票用途", isOn: $allowUpload)
                            .toggleStyle(.switch)
                        Text("包括现有目录名、代表性文件名、少量正文及本批发票的来源文件夹名称、原子目录和用途说明。完整搜索索引留在本机。云端 API 可能产生费用；不勾选时不发送目录线索和文件内容。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存配置") {
                    if model.saveAI(provider: provider,
                                    endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                                    model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                                    allowUpload: allowUpload, key: key) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 620)
        .textFieldStyle(.roundedBorder)
        .onChange(of: endpoint) { _, _ in allowUpload = false; key = "" }
    }
}

// MARK: - Rules

private struct RulesView: View {
    @ObservedObject var model: AppModel
    @State private var keyword = ""
    @State private var folder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard("新增规则", systemImage: "plus.circle") {
                HStack(spacing: 9) {
                    TextField("关键词，例如：客户A", text: $keyword)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    TextField("子目录，例如：工作/客户A", text: $folder)
                    Button("添加") {
                        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                        let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty, RuleEngine.validateFolder(f) else {
                            model.error = "请填写关键词和有效子目录，例如：工作/客户A。不能使用绝对路径、隐藏目录或 ..。"
                            return
                        }
                        model.config.rules.append(SortRule(keyword: k, folder: f))
                        model.save()
                        keyword = ""; folder = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                }
                Text("名称中包含关键词，就放到指定子目录。规则从上到下匹配，优先于 AI。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if model.config.rules.isEmpty {
                SettingsCard {
                    ContentUnavailableView {
                        Label("把你的习惯，交给落格", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("例如「客户A」→「客户/客户A」，或「旅行」→「生活/旅行」。\n没有自定义规则时，会根据已有目录和文件内容整理。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 210)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(model.config.rules.enumerated()), id: \.element.id) { index, rule in
                        InsetRow {
                            HStack(spacing: 12) {
                                Toggle("", isOn: Binding(
                                    get: { model.config.rules.first(where: { $0.id == rule.id })?.enabled ?? false },
                                    set: { enabled in
                                        if let i = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                            model.config.rules[i].enabled = enabled
                                            model.save()
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                Text(rule.keyword)
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 150, alignment: .leading)
                                    .lineLimit(1)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Text(rule.folder)
                                    .font(.system(size: 12))
                                    .foregroundStyle(DropTheme.accent)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Button {
                                    model.config.rules.swapAt(index, index - 1); model.save()
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.plain)
                                .disabled(index == 0)
                                .help("提高优先级")
                                Button {
                                    model.config.rules.removeAll { $0.id == rule.id }; model.save()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red.opacity(0.75))
                                .help("删除规则")
                            }
                        }
                    }
                }
                .disabled(model.busy)
            }
        }
    }
}

// MARK: - History

private struct HistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("共 \(model.records.count) 条记录 · 显示最近 300 条")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("打开记录文件夹", action: model.openRecords)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if model.records.isEmpty {
                SettingsCard {
                    ContentUnavailableView {
                        Label("每一次整理，都有迹可循", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("拖入第一份文件后，这里会显示归档位置和撤销入口。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(model.records.prefix(300))) { record in
                        HistoryRow(model: model, record: record)
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    @ObservedObject var model: AppModel
    let record: ArchiveRecord

    private var tint: Color {
        switch record.status {
        case .moved: DropTheme.accent
        case .duplicate: .orange
        case .failed, .needsReview: .red
        case .undone, .unchanged, .planned, .undoing: .secondary
        }
    }

    private var symbol: String {
        switch record.status {
        case .moved: "doc.badge.arrow.up"
        case .undone: "arrow.uturn.backward.circle"
        case .duplicate: "doc.on.doc"
        case .failed: "exclamationmark.triangle"
        case .needsReview: "questionmark.circle"
        case .unchanged: "checkmark.circle"
        case .planned, .undoing: "clock"
        }
    }

    var body: some View {
        InsetRow {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.11))
                        .frame(width: 36, height: 36)
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(record.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(label(record))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.10), in: Capsule())
                    }
                    Text(record.destination)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(record.destination)
                    Text("\(record.reason) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    if let detail = record.detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                Button { model.reveal(record) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
                if record.status == .moved {
                    Button("撤销") { model.undo(record) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.busy)
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
