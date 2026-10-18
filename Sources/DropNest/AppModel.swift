import AppKit
import SwiftUI
import ServiceManagement
import DropNestCore

actor ArchiveWorker {
    let journal: ArchiveJournal
    init(file: URL) throws { journal = try ArchiveJournal(file: file) }
    func history() -> [ArchiveRecord] { journal.records }
    func move(_ url: URL, root: URL, decision: Decision, fromPending: Bool,
              invoiceSource: URL? = nil, expectedStamp: FileStamp? = nil, originalFiles: Set<URL> = []) throws -> ArchiveRecord {
        if let expectedStamp, try FileStamp.read(url) != expectedStamp {
            throw ArchiveError.invalid("文件在预览或分类后发生变化，已保留原处，请重新扫描。")
        }
        if let invoiceSource { return try journal.archiveInvoice(source: url, root: root, decision: decision, sourceFolder: invoiceSource, expectedStamp: expectedStamp, originalFiles: originalFiles) }
        else if fromPending { return try journal.archivePending(source: url, root: root, decision: decision) }
        else { return try journal.archive(source: url, root: root, decision: decision) }
    }
    func undo(_ id: UUID) throws { try journal.undo(id: id) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var config: Configuration
    @Published var records: [ArchiveRecord] = []
    @Published var busy = false
    @Published var queueCount = 0
    @Published var status = "给散落的文件，一个合适的位置。"
    @Published var error: String?
    @Published var aiStatus = SmartClassifier.availability.message
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var testingAI = false
    @Published var library = LibrarySnapshot()
    @Published var indexing = false
    @Published var indexProgress = ""
    @Published var searchQuery = ""
    @Published var searchResults: [LibrarySearchHit] = []
    @Published var searching = false
    @Published var monitoringLibrary = false
    @Published var settingsTab = 0
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var checkingDuplicates = false
    @Published var duplicateProgress = "尚未检查"
    @Published var cleaningDuplicates = false
    @Published var duplicateCleanupResult: DuplicateCleanupResult?
    @Published var invoiceSourceFolder: URL?
    @Published var invoicePurpose = ""
    @Published var invoiceCategories = InvoiceBatch.defaultCategories.joined(separator: "、")
    @Published var invoiceBatch: InvoiceBatch?
    @Published var scanningInvoices = false
    @Published var invoiceMessage = "选择发票文件夹，逐份按用途和类型整理。"
    var showSettings: () -> Void = {}
    var showSearch: () -> Void = {}
    private struct QueuedFile {
        let url: URL
        var fromPending = false
        var invoice: InvoiceContext?
        var expectedStamp: FileStamp?
        /// Set when the file came out of a split folder; a hint for the classifier.
        var sourceFolder: String?
    }
    private var queue: [QueuedFile] = []
    private var worker: ArchiveWorker?
    private let defaultsKey = "DropNest.Configuration.v1"
    private let dataDirectory: URL
    private let defaults: UserDefaults
    private var libraryWorker: LibraryWorker?
    private var libraryMonitor: LibraryMonitor?
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var duplicateTask: Task<Void, Never>?
    private var duplicateGeneration = UUID()
    private var invoiceScanTask: Task<Void, Never>?
    private var invoiceScanGeneration = UUID()
    private var indexGeneration = UUID()
    private var indexRefreshPending = false

    init(dataDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.dataDirectory = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DropNest", isDirectory: true)
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(Configuration.self, from: data) {
            config = saved
        } else { config = Configuration() }
        do { worker = try ArchiveWorker(file: self.dataDirectory.appendingPathComponent("history.json")) }
        catch { self.error = "无法读取整理记录。为保护记录，已停止归档：\(error.localizedDescription)" }
        libraryWorker = LibraryWorker(storage: self.dataDirectory.appendingPathComponent("library.json"))
        refreshAI()
        Task { await refreshHistory() }
        resetLibrary()
    }

    func save() {
        do { defaults.set(try JSONEncoder().encode(config), forKey: defaultsKey) }
        catch { self.error = error.localizedDescription }
    }
    func refreshAI() {
        aiStatus = config.aiProvider == .system ? SmartClassifier.availability.message : "AI 接口：\(URL(string: config.apiEndpoint)?.host ?? "待配置") · \(config.apiModel)"
    }
    func saveAI(provider: AIProvider, endpoint: String, model: String, allowUpload: Bool, key: String) -> Bool {
        if provider == .compatible {
            guard CompatibleAPI.endpoint(endpoint) != nil, !model.trimmingCharacters(in: .whitespaces).isEmpty else {
                error = "请填写有效的 Chat Completions 完整地址与模型名称。"; return false
            }
            if !key.isEmpty {
                do { try CredentialStore.save(key, endpoint: endpoint) }
                catch { self.error = error.localizedDescription; return false }
            }
        }
        config.aiProvider = provider; config.apiEndpoint = endpoint; config.apiModel = model
        config.allowContentUpload = allowUpload; config.allowDirectoryContextUpload = allowUpload
        save(); refreshAI(); return true
    }
    func testAI() {
        guard !testingAI else { return }
        testingAI = true
        let settings = config
        Task {
            do {
                _ = try await RemoteClassifier.classify(nil, config: settings)
                aiStatus = "连接成功 · 模型已响应（仅发送虚构样例）"
            } catch { aiStatus = "连接失败：\(error.localizedDescription)" }
            testingAI = false
        }
    }
    func refreshHistory() async { if let worker { records = await worker.history() } }
    var root: URL? { config.rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var completedCount: Int { records.filter { $0.status == .moved }.count }

    func refreshLibrary() {
        guard let root, let libraryWorker else {
            library = LibrarySnapshot(); searchResults = []; return
        }
        guard !indexing else { indexRefreshPending = true; return }
        indexRefreshPending = false
        let generation = UUID(); indexGeneration = generation
        indexing = true; indexProgress = "正在读取目录结构…"
        indexTask = Task {
            defer {
                if indexGeneration == generation {
                    indexing = false; indexTask = nil
                    if indexRefreshPending && !busy { refreshLibrary() }
                }
            }
            do {
                let result = try await libraryWorker.rebuild(root: root) { [weak self] current, total in
                    await self?.updateIndexProgress(current: current, total: total, generation: generation)
                }
                guard !Task.isCancelled, indexGeneration == generation else { return }
                library = result; indexProgress = "目录与文件索引已更新"
                searchLibrary()
            } catch is CancellationError {
            } catch { if indexGeneration == generation { self.error = "目录索引未完成：\(error.localizedDescription)" } }
        }
    }
    private func updateIndexProgress(current: Int, total: Int, generation: UUID) {
        guard indexGeneration == generation else { return }
        indexProgress = "正在建立内容索引 · \(current)/\(total)"
    }
    private func resetLibrary() {
        invoiceScanTask?.cancel(); invoiceScanGeneration = UUID(); invoiceBatch = nil; scanningInvoices = false
        duplicateTask?.cancel(); duplicateGeneration = UUID()
        duplicateGroups = []; checkingDuplicates = false; duplicateProgress = "尚未检查"
        duplicateCleanupResult = nil
        libraryMonitor?.stop(); libraryMonitor = nil; monitoringLibrary = false
        indexRefreshPending = false
        indexTask?.cancel(); indexTask = nil; indexGeneration = UUID(); indexing = false
        searchTask?.cancel(); library = LibrarySnapshot(); searchResults = []; searching = false
        if let root {
            do {
                libraryMonitor = try LibraryMonitor(root: root, excluding: [dataDirectory]) { [weak self] in
                    guard let self else { return }
                    if self.busy { self.indexRefreshPending = true }
                    else { self.refreshLibrary() }
                }
                monitoringLibrary = true
            } catch { self.error = error.localizedDescription }
        }
        refreshLibrary()
    }
    func clearRoot() { guard !busy else { return }; config.rootPath = nil; save(); resetLibrary() }
    func scanDuplicates() {
        guard !busy, !checkingDuplicates, let root else { return }
        duplicateCleanupResult = nil
        startDuplicateScan(root: root)
    }
    private func startDuplicateScan(root: URL) {
        let generation = UUID(); duplicateGeneration = generation
        checkingDuplicates = true; duplicateGroups = []; duplicateProgress = "正在检查文件内容…"
        duplicateTask = Task.detached(priority: .utility) { [self] in
            do {
                let groups = try DuplicateFiles.groups(root: root) { current, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.duplicateGeneration == generation, self.checkingDuplicates else { return }
                        self.duplicateProgress = "正在比对内容 · \(current)/\(total)"
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self, self.duplicateGeneration == generation else { return }
                    self.duplicateGroups = groups; self.checkingDuplicates = false
                    self.duplicateProgress = "找到 \(groups.count) 组重复文件 · \(groups.reduce(0) { $0 + $1.documents.count }) 个文件"
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.duplicateGeneration == generation else { return }
                    self.checkingDuplicates = false; self.duplicateProgress = "检查未完成，请重新检查"
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                }
            }
        }
    }
    var duplicateCleanupCount: Int { duplicateGroups.reduce(0) { $0 + max(0, $1.documents.count - 1) } }
    func cleanDuplicates() {
        guard !busy, !checkingDuplicates, !duplicateGroups.isEmpty, let root else { return }
        let groups = duplicateGroups
        let generation = UUID(); duplicateGeneration = generation
        busy = true; cleaningDuplicates = true; duplicateCleanupResult = nil
        duplicateProgress = "正在核对并移到废纸篓…"; status = duplicateProgress
        duplicateTask = Task.detached(priority: .utility) { [self] in
            let result = DuplicateCleanup.clean(groups: groups, root: root, progress: { current, total in
                Task { @MainActor [weak self] in
                    guard let self, self.duplicateGeneration == generation, self.cleaningDuplicates else { return }
                    self.duplicateProgress = "正在清理 · \(current)/\(total)"
                    self.status = self.duplicateProgress
                }
            })
            await MainActor.run { [weak self] in
                guard let self, self.duplicateGeneration == generation else { return }
                self.cleaningDuplicates = false; self.busy = false
                self.duplicateCleanupResult = result; self.duplicateGroups = []
                self.status = result.summary; self.duplicateProgress = result.summary
                self.refreshLibrary()
                self.startDuplicateScan(root: root)
                self.enqueue([])
            }
        }
    }
    func searchLibrary() {
        searchTask?.cancel()
        guard let libraryWorker, let root else { searchResults = []; return }
        let query = searchQuery; let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        searching = true
        searchTask = Task {
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            let results = await libraryWorker.search(query: query, root: path)
            guard !Task.isCancelled else { return }
            searchResults = results; searching = false
        }
    }

    func chooseInvoiceFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择本批发票文件夹"; panel.message = "逐份读取发票，保留来源文件夹名称，再按用途和类型归档。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "选择发票文件夹"
        if panel.runModal() == .OK, let folder = panel.url { setInvoiceFolder(folder) }
    }
    func setInvoiceFolder(_ folder: URL) {
        guard !busy else { return }
        guard let root else { error = "请先在归档设置中选择归档总目录。"; return }
        invoiceScanTask?.cancel()
        let generation = UUID(); invoiceScanGeneration = generation
        invoiceSourceFolder = folder; invoiceBatch = nil; scanningInvoices = true; invoiceMessage = "正在扫描发票文件夹…"
        invoiceScanTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let batch = try InvoiceBatch.scan(folder: folder, archiveRoot: root)
                await MainActor.run { [weak self] in
                    guard let self, self.invoiceScanGeneration == generation else { return }
                    self.invoiceBatch = batch; self.scanningInvoices = false
                    self.invoiceMessage = "找到 \(batch.items.count) 个可读取文件" + (batch.unsupportedCount > 0 ? "，另有 \(batch.unsupportedCount) 个不支持的文件保留原处。" : "。")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.invoiceScanGeneration == generation else { return }
                    self.scanningInvoices = false; self.invoiceMessage = "扫描未完成，请重新选择或扫描。"
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                }
            }
        }
    }
    func enqueueInvoices() {
        guard !busy, !scanningInvoices, let batch = invoiceBatch, !batch.items.isEmpty else { return }
        guard config.useAI else { error = "发票用途分类需要启用 AI，请在归档设置中开启。"; return }
        do {
            let categories = invoiceCategories.split(whereSeparator: { ",，、;；\n".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let originals = Set(batch.items.map(\.url))
            let items = try batch.items.map { item in
                QueuedFile(url: item.url, invoice: try InvoiceContext(sourceFolder: batch.sourceFolder,
                    relativeFolder: item.relativeFolder, purpose: invoicePurpose, categories: categories, originalFiles: originals), expectedStamp: item.stamp)
            }
            invoiceBatch = nil; invoiceMessage = "已加入 \(items.count) 个文件，正在按用途类型整理。"
            enqueueItems(items)
        } catch { self.error = error.localizedDescription }
    }
    func openDocument(_ document: LibraryDocument, reveal: Bool) {
        guard let root else { return }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = base.appendingPathComponent(document.path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
            error = "文件已移动或不在归档目录中，请刷新索引后重试。"; return
        }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        else if !NSWorkspace.shared.open(file) { error = "无法打开此文件，可用“在 Finder 中显示”查看。" }
    }

    func chooseRoot() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择文件归档位置"; panel.message = "落格会学习此目录下已有的文件夹结构，并建立文件搜索索引。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "设为归档位置"
        if panel.runModal() == .OK, let url = panel.url {
            setRoot(url)
        }
    }
    func setRoot(_ url: URL) {
        guard !busy else { return }
        config.rootPath = url.path; save(); resetLibrary(); status = "准备好了，把文件拖进来吧。"
    }
    func reorganizePending() {
        guard !busy, let root else { return }
        do {
            let pending = root.appendingPathComponent("待整理", isDirectory: true)
            guard FileManager.default.fileExists(atPath: pending.path) else { status = "待整理中没有文件。"; return }
            guard pending.standardizedFileURL.resolvingSymlinksInPath().path == root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("待整理").path else {
                throw ArchiveError.invalid("待整理目录不能是符号链接。")
            }
            let files = try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).sorted { $0.path < $1.path }
            guard !files.isEmpty else { status = "待整理中没有文件。"; return }
            enqueue(files, fromPending: true)
        } catch { self.error = error.localizedDescription }
    }
    func enqueue(_ urls: [URL], fromPending: Bool = false) {
        enqueueItems(urls.map { QueuedFile(url: $0, fromPending: fromPending) })
    }
    /// The drop panel asks how to treat folders only when this is true.
    func needsFolderChoice(_ urls: [URL]) -> Bool {
        config.folderDropMode == .ask && urls.contains(where: FolderSplit.isSplittable)
    }
    func handleDrop(_ urls: [URL]) {
        enqueueDrop(urls, split: config.folderDropMode == .split)
    }
    /// With `split`, every folder is replaced by the files inside it, each
    /// classified on its own; the emptied folders stay where they were.
    func enqueueDrop(_ urls: [URL], split: Bool) {
        guard split else { enqueue(urls); return }
        var items: [QueuedFile] = []
        var splitFolders = 0
        for url in urls {
            guard FolderSplit.isSplittable(url) else { items.append(QueuedFile(url: url)); continue }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let files = try FolderSplit.items(in: url, root: root)
                items += files.map { QueuedFile(url: $0.url, sourceFolder: $0.sourceFolder) }
                splitFolders += 1
            } catch { self.error = error.localizedDescription }
        }
        if splitFolders > 0 && items.isEmpty { status = "拆分的文件夹里没有可归档的文件。"; return }
        if splitFolders > 0 { status = "已拆分 \(splitFolders) 个文件夹，共 \(items.count) 个文件待归档。" }
        enqueueItems(items)
    }
    private func enqueueItems(_ items: [QueuedFile]) {
        guard root != nil else { error = "请先选择归档位置，再拖入文件。"; return }
        guard worker != nil else { error = "整理记录不可用，暂时无法归档。"; return }
        var existing = Set(queue.map { $0.url.standardizedFileURL })
        queue.append(contentsOf: items.filter { $0.url.isFileURL && existing.insert($0.url.standardizedFileURL).inserted })
        queueCount = queue.count
        guard !busy, !queue.isEmpty else { return }
        busy = true
        Task {
            var successes = 0
            var failures = 0
            var unresolved = 0
            var duplicates = 0
            var unchanged = 0
            var nonInvoices = 0
            var invoiceReview = 0
            var hadInvoices = false
            refreshLibrary()
            if let indexTask { await indexTask.value }
            while !queue.isEmpty {
                let item = queue.removeFirst(); let url = item.url; queueCount = queue.count + 1
                let settings = config
                guard let root = settings.rootPath.map({ URL(fileURLWithPath: $0) }), let worker else { break }
                status = "正在整理 · \(url.lastPathComponent)"
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    _ = try url.resourceValues(forKeys: [.isDirectoryKey])
                    var decision: Decision?
                    if let invoice = item.invoice {
                        hadInvoices = true; invoiceMessage = "正在识别发票用途 · \(url.lastPathComponent)"
                        guard settings.useAI else { throw ArchiveError.invalid("AI 已关闭，发票保留原处。") }
                        guard let expected = item.expectedStamp, try FileStamp.read(url) == expected else {
                            throw ArchiveError.invalid("文件在扫描后发生变化，请重新扫描发票文件夹。")
                        }
                        decision = try await RemoteClassifier.invoice(url, context: invoice, config: settings)
                    } else { decision = RuleEngine.customDecision(for: url, rules: settings.rules) }
                    var fallbackNote = "AI 未启用，留待整理"
                    if item.invoice == nil, decision == nil, settings.useAI {
                        let expectedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
                        if library.rootPath == expectedRoot {
                            do { decision = try await RemoteClassifier.route(url, config: settings, library: library, sourceFolder: item.sourceFolder ?? "") }
                            catch { fallbackNote = "AI 未完成目录判断，留待整理"; aiStatus = error.localizedDescription }
                        } else { fallbackNote = "目录索引不可用，留待整理" }
                    }
                    if item.invoice == nil, decision == nil {
                        decision = Decision(folder: "待整理", reason: fallbackNote)
                    }
                    if item.invoice != nil && decision == nil {
                        nonInvoices += 1
                    } else if item.fromPending && (decision!.folder == "待整理" || decision!.folder.hasPrefix("待整理/")) {
                        unresolved += 1
                    } else {
                        let record = try await worker.move(url, root: root, decision: decision!, fromPending: item.fromPending,
                            invoiceSource: item.invoice?.sourceFolder, expectedStamp: item.expectedStamp, originalFiles: item.invoice?.originalFiles ?? [])
                        if record.status == .duplicate { duplicates += 1 }
                        else if record.status == .unchanged { unchanged += 1 }
                        else {
                            if library.rootPath == root.standardizedFileURL.resolvingSymlinksInPath().path {
                                library.registerFolder(decision!.folder)
                            }
                            successes += 1
                            if item.invoice != nil, decision!.folder.split(separator: "/").contains(where: { $0 == "用途待确认" || $0 == "分类待确认" }) { invoiceReview += 1 }
                        }
                    }
                } catch { failures += 1; self.error = "\(url.lastPathComponent)：\(error.localizedDescription)" }
                if scoped { url.stopAccessingSecurityScopedResource() }
                await refreshHistory()
            }
            busy = false; queueCount = 0
            status = failures == 0 ? "已整理 \(successes) 个文件，一切井井有条。" : "已整理 \(successes) 个文件，\(failures) 个未完成。"
            if unresolved > 0 { status = "已整理 \(successes) 个文件，\(unresolved) 个仍需确认。" + (failures > 0 ? "\(failures) 个未完成。" : "") }
            if duplicates > 0 { status = "已整理 \(successes) 个，\(duplicates) 个重复文件保留原处。" + (failures > 0 ? "\(failures) 个未完成。" : "") + (unresolved > 0 ? "\(unresolved) 个仍需确认。" : "") }
            if unchanged > 0 { status += "\(unchanged) 个位置已正确。" }
            if nonInvoices > 0 { status += "\(nonInvoices) 个非票据或无法识别的文件保留原处。" }
            if invoiceReview > 0 { status += "\(invoiceReview) 个用途或类型待确认。" }
            if hadInvoices { invoiceMessage = status }
            refreshLibrary()
        }
    }
    func undo(_ record: ArchiveRecord) {
        guard !busy, let worker else { return }
        busy = true
        Task {
            do { try await worker.undo(record.id); status = "已放回原处 · \(record.name)" }
            catch { self.error = error.localizedDescription }
            await refreshHistory(); busy = false
            refreshLibrary()
        }
    }
    func reveal(_ record: ArchiveRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.status == .undone ? record.source : record.destination)])
    }
    func openRoot() { if let root { NSWorkspace.shared.open(root) } }
    func openRecords() { NSWorkspace.shared.open(dataDirectory) }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { self.error = "登录启动设置失败：\(error.localizedDescription)" }
    }
}
