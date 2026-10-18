import SwiftUI
import DropNestCore

struct DuplicateFilesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("找出内容完全相同的文件")
                        .font(.system(size: 12, weight: .medium))
                    Text("每组保留标记的一份，其余可一键移到废纸篓。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(model.checkingDuplicates ? "检查中…" : "检查重复文件", action: model.scanDuplicates)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.checkingDuplicates || model.busy || model.root == nil)
                Button(model.cleaningDuplicates ? "清理中…" : "一键清理（\(model.duplicateCleanupCount) 份）", action: model.cleanDuplicates)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(model.duplicateCleanupCount > 0 ? Color.red : DropTheme.accent)
                    .disabled(model.busy || model.checkingDuplicates || model.duplicateCleanupCount == 0)
            }

            HStack(spacing: 8) {
                Text(model.duplicateProgress)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if model.checkingDuplicates || model.cleaningDuplicates { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let result = model.duplicateCleanupResult {
                SettingsCard(result.issues.isEmpty ? "清理完成" : "清理结果", systemImage: result.issues.isEmpty ? "checkmark.circle" : "exclamationmark.circle") {
                    Text(result.summary)
                        .font(.system(size: 11, weight: .medium))
                    if !result.issues.isEmpty {
                        DisclosureGroup("查看 \(result.issues.count) 个未清理文件的原因") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                                    Text("\(issue.path)：\(issue.message)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.system(size: 11))
                    }
                }
            }

            if model.duplicateGroups.isEmpty {
                SettingsCard {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: "doc.on.doc")
                    } description: {
                        Text("按文件大小筛选，再核对完整内容。\n不检查隐藏文件、符号链接、应用包及 node_modules；最多检查 20,000 个条目。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.duplicateGroups) { group in
                        SettingsCard {
                            HStack(spacing: 8) {
                                Label("\(group.documents.count) 份相同内容", systemImage: "doc.on.doc")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(ByteCountFormatter.string(fromByteCount: group.documents[0].size, countStyle: .file))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            SettingsCardDivider()
                            VStack(spacing: 0) {
                                ForEach(Array(group.documents.enumerated()), id: \.element.id) { index, document in
                                    if index > 0 { SettingsCardDivider().opacity(0.6) }
                                    HStack(spacing: 10) {
                                        Text(index == 0 ? "保留" : "待清理")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(index == 0 ? DropTheme.accent : Color.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                (index == 0 ? DropTheme.accent : Color.secondary).opacity(0.10),
                                                in: Capsule()
                                            )
                                            .frame(width: 46)
                                        Text(document.path)
                                            .font(.system(size: 11))
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                            .help(document.path)
                                        Spacer(minLength: 6)
                                        Button("打开") { model.openDocument(document, reveal: false) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        Button { model.openDocument(document, reveal: true) } label: {
                                            Image(systemName: "folder")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("在 Finder 中显示")
                                    }
                                    .padding(.vertical, 7)
                                }
                            }
                        }
                    }
                }
                Text("每组按路径排序保留第一份，清理前再次核对内容；已变化的文件会跳过。可从系统废纸篓恢复。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyTitle: String {
        if model.root == nil { return "先在归档设置中选择总目录" }
        if model.checkingDuplicates { return "正在逐一比对文件内容" }
        if model.duplicateProgress == "尚未检查" { return "检查归档目录中的重复文件" }
        if model.duplicateProgress.hasPrefix("找到 0") { return "没有发现重复文件" }
        return "检查未完成"
    }
}
