import SwiftUI
import DropNestCore

struct DuplicateFilesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("找出内容完全相同的文件").font(.headline)
                    Text("每组保留标记的一份，其余可一键移到废纸篓。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.checkingDuplicates ? "检查中…" : "检查重复文件", action: model.scanDuplicates)
                    .disabled(model.checkingDuplicates || model.busy || model.root == nil)
                Button(model.cleaningDuplicates ? "清理中…" : "一键清理（\(model.duplicateCleanupCount) 份）", action: model.cleanDuplicates)
                    .disabled(model.busy || model.checkingDuplicates || model.duplicateCleanupCount == 0)
            }
            HStack {
                Text(model.duplicateProgress).font(.system(size: 11)).foregroundStyle(.secondary)
                if model.checkingDuplicates || model.cleaningDuplicates { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let result = model.duplicateCleanupResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.summary).font(.system(size: 11, weight: .medium))
                    if !result.issues.isEmpty {
                        DisclosureGroup("查看 \(result.issues.count) 个未清理文件的原因") {
                            ScrollView {
                                Text(result.issues.map { "\($0.path)：\($0.message)" }.joined(separator: "\n"))
                                    .font(.system(size: 10)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 100)
                        }.font(.system(size: 11))
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            }
            if model.duplicateGroups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.on.doc").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text(model.root == nil ? "先在归档设置中选择总目录" : model.checkingDuplicates ? "正在逐一比对文件内容" : model.duplicateProgress == "尚未检查" ? "检查归档目录中的重复文件" : model.duplicateProgress.hasPrefix("找到 0") ? "没有发现重复文件" : "检查未完成")
                        .font(.headline)
                    Text("按文件大小筛选，再核对完整内容。\n不检查隐藏文件、符号链接、应用包及 node_modules；最多检查 20,000 个条目。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.duplicateGroups) { group in
                            VStack(alignment: .leading, spacing: 9) {
                                Text("\(group.documents.count) 份相同内容 · 每份 \(ByteCountFormatter.string(fromByteCount: group.documents[0].size, countStyle: .file))")
                                    .font(.system(size: 12, weight: .semibold))
                                ForEach(group.documents) { document in
                                    HStack(spacing: 10) {
                                        Text(document.path == group.documents[0].path ? "保留" : "待清理")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(document.path == group.documents[0].path ? .green : .secondary)
                                            .frame(width: 36)
                                        Text(document.path).font(.system(size: 11)).lineLimit(2).help(document.path)
                                        Spacer(minLength: 4)
                                        Button("打开") { model.openDocument(document, reveal: false) }
                                        Button("在 Finder 中显示") { model.openDocument(document, reveal: true) }
                                    }
                                }
                            }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                Text("每组按路径排序保留第一份，清理前再次核对内容；已变化的文件会跳过。可从系统废纸篓恢复。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
