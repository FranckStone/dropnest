import SwiftUI
import DropNestCore

struct LibrarySearchView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                SettingsSearchField(
                    text: $model.searchQuery,
                    placeholder: "搜索文件名、目录或内容，例如：客户A 合同"
                )
                .onChange(of: model.searchQuery) { _, _ in model.searchLibrary() }
                Button("刷新索引", action: model.refreshLibrary)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.indexing || model.busy || model.root == nil)
            }

            HStack(spacing: 8) {
                Text(model.indexing ? model.indexProgress : "找到 \(model.searchResults.count) 个文件 · 索引共 \(model.library.documents.count) 个文件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if model.indexing || model.searching { ProgressView().controlSize(.small) }
                Spacer()
                if model.library.updated != .distantPast {
                    Text(model.library.updated.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if model.library.incomplete {
                Label("部分文件或目录未能完整索引；可在 Finder 中查看全部文件。", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if model.searchResults.isEmpty {
                SettingsCard {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("搜索包含原有文件和新归档文件。支持文件名、路径及可提取的正文；\n图片可搜 OCR 文字，未提取正文的格式仍可按文件名查找。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(Array(model.searchResults.prefix(300))) { hit in
                        InsetRow {
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(DropTheme.accent.opacity(0.10))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(DropTheme.accent)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.document.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Text(hit.document.path)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(hit.document.path)
                                    if !hit.snippet.isEmpty {
                                        Text(hit.snippet)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Text("\(hit.document.modified.formatted(date: .abbreviated, time: .omitted)) · \(indexLabel(hit.document))")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 8)
                                HStack(spacing: 6) {
                                    Button("打开") { model.openDocument(hit.document, reveal: false) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    Button { model.openDocument(hit.document, reveal: true) } label: {
                                        Image(systemName: "folder")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("在 Finder 中显示")
                                }
                            }
                        }
                    }
                    if model.searchResults.count > 300 {
                        Text("显示前 300 个结果，请补充关键词缩小范围。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .onAppear { model.searchLibrary() }
    }

    private var emptyTitle: String {
        if model.root == nil { return "先选择归档总目录" }
        if model.indexing { return "正在建立本地搜索索引" }
        return "没有找到匹配的文件"
    }

    private func indexLabel(_ document: LibraryDocument) -> String {
        if document.text.isEmpty { return "仅文件名与路径" }
        return document.textTruncated ? "正文部分索引" : "正文已索引"
    }
}
