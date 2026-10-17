import SwiftUI
import DropNestCore

struct LibrarySearchView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文件名、目录或内容，例如：客户A 合同", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.searchQuery) { _, _ in model.searchLibrary() }
                if !model.searchQuery.isEmpty { Button("清空") { model.searchQuery = "" } }
                Button("刷新索引", action: model.refreshLibrary).disabled(model.indexing || model.busy || model.root == nil)
            }
            HStack {
                Text(model.indexing ? model.indexProgress : "找到 \(model.searchResults.count) 个文件 · 索引共 \(model.library.documents.count) 个文件")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.indexing || model.searching { ProgressView().controlSize(.small) }
                Spacer()
                if model.library.updated != .distantPast {
                    Text(model.library.updated.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if model.library.incomplete {
                Text("部分文件或目录未能完整索引；可在 Finder 中查看全部文件。").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if model.searchResults.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text(model.root == nil ? "先选择归档总目录" : model.indexing ? "正在建立本地搜索索引" : "没有找到匹配的文件").font(.headline)
                    Text("搜索包含原有文件和新归档文件。支持文件名、路径及可提取的正文；\n图片可搜 OCR 文字，未提取正文的格式仍可按文件名查找。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(model.searchResults.prefix(300))) { hit in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "doc.text").font(.system(size: 23)).foregroundStyle(.secondary).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(hit.document.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text(hit.document.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(hit.document.path)
                                    if !hit.snippet.isEmpty { Text(hit.snippet).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                                    Text("\(hit.document.modified.formatted(date: .abbreviated, time: .omitted)) · \(hit.document.text.isEmpty ? "仅文件名与路径" : hit.document.textTruncated ? "正文部分索引" : "正文已索引")")
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 5)
                                Button("打开") { model.openDocument(hit.document, reveal: false) }
                                Button { model.openDocument(hit.document, reveal: true) } label: { Image(systemName: "folder") }
                                    .help("在 Finder 中显示")
                            }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if model.searchResults.count > 300 { Text("显示前 300 个结果，请补充关键词缩小范围。").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                }
            }
        }.onAppear { model.searchLibrary() }
    }
}
