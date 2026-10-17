import SwiftUI
import DropNestCore

struct InvoiceImportView: View {
    @ObservedObject var model: AppModel
    @State private var targeted = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("发票按用途，各归其类").font(.headline)
                        Text("来源文件夹 → 用途 → 类型，例如：10月差旅 / 出差报销 / 住宿。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("选择发票文件夹…", action: model.chooseInvoiceFolder).disabled(model.busy || model.scanningInvoices)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08))
                    VStack(spacing: 7) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text(model.invoiceSourceFolder?.lastPathComponent ?? "也可以把一批发票的文件夹拖到这里").font(.system(size: 12, weight: .medium))
                        if let folder = model.invoiceSourceFolder {
                            Text(folder.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.padding(12).allowsHitTesting(false)
                    DropReceiver(onDrop: { urls in
                        guard urls.count == 1 else { model.error = "请每次选择一个发票文件夹。"; return }
                        model.setInvoiceFolder(urls[0])
                    }, onHover: { targeted = $0 }, onClick: model.chooseInvoiceFolder)
                }.frame(height: 100)
                LabeledContent("本批用途") {
                    TextField("例如：出差报销、客户招待；留空时参考原文件夹和票据", text: $model.invoicePurpose)
                        .textFieldStyle(.roundedBorder).disabled(model.busy)
                }
                LabeledContent("用途类型") {
                    TextField("交通、住宿、餐饮、办公用品…", text: $model.invoiceCategories)
                        .textFieldStyle(.roundedBorder).disabled(model.busy)
                }
                Text("用途和每个类型最多40字，类型用顿号或逗号分隔。明确填写的用途优先；留空且无法判断时标记“用途待确认”。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Text(model.invoiceMessage).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    if model.scanningInvoices { ProgressView().controlSize(.small) }
                    Spacer()
                    if let folder = model.invoiceSourceFolder {
                        Button("重新扫描") { model.setInvoiceFolder(folder) }.disabled(model.busy || model.scanningInvoices)
                    }
                    Button("开始按用途整理", action: model.enqueueInvoices)
                        .disabled(model.busy || model.scanningInvoices || model.invoiceBatch?.items.isEmpty != false || model.root == nil)
                }
                if let batch = model.invoiceBatch {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(batch.items.prefix(5)), id: \.url) { item in
                            Text((item.relativeFolder.isEmpty ? "" : item.relativeFolder + "/") + item.url.lastPathComponent)
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if batch.items.count > 5 { Text("另有 \(batch.items.count - 5) 个文件").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }
                Text("支持 PDF、图片、XML、文本和 Word 票据。扫描 PDF 会识别前3页文字。子文件夹名称作为用途线索，非票据和不支持的格式保留原处；原文件夹保留，已移动的发票可在整理记录撤销。整理前仍会检查重复文件。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.bottom, 4)
        }
    }
}
