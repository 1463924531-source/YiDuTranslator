import AppKit
import SwiftUI
import TranslatorCore
import UniformTypeIdentifiers

@MainActor
struct DocumentsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @State private var dropTargeted = false
    @State private var warningsExpanded = false
    private let accent = AppTheme.accent
    private var isWorking: Bool { store.importing || store.documentBusy }
    private var selected: DocumentRow? { store.documentRows.first { $0.id == store.selectedSegmentID } }
    private var remaining: Int {
        store.documentRows.filter { !$0.isComplete || !usesCurrentSettings($0) }.count
    }

    private func usesCurrentSettings(_ row: DocumentRow) -> Bool {
        row.request?.direction == settings.direction
            && row.request?.style == settings.style
            && row.request?.glossary == settings.glossary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.importing { importProgress }
            if store.documentRows.isEmpty {
                emptyState
            } else {
                documentToolbar
                if !store.documentWarnings.isEmpty { warnings }
                Divider()
                HSplitView {
                    paragraphList.frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
                    paragraphDetail.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                }
                footer
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: acceptDrop)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("文件对照").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text(store.documentTitle.isEmpty ? "把长文拆成段落，逐段读懂。" : store.documentTitle)
                    .foregroundStyle(.secondary).lineLimit(1).help(store.documentTitle)
            }
            Spacer(minLength: 12)
            Button(action: store.chooseDocument) { Label("导入文件", systemImage: "square.and.arrow.down") }
                .disabled(isWorking)
            if !store.documentRows.isEmpty {
                Button(action: store.exportDocument) { Label("导出对照文本", systemImage: "square.and.arrow.up") }
                    .disabled(isWorking)
                Button(action: store.closeDocument) { Image(systemName: "xmark.circle") }
                    .help("关闭文件并清除本次对照内容").disabled(isWorking)
            }
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.on.doc").font(.system(size: 44, weight: .light)).foregroundStyle(accent)
            Text(store.importing ? "正在读取文件…" : "拖入 PDF 或 Word").font(.title2.weight(.medium))
            Text("支持 PDF、DOCX 和 DOC。原文与译文按段落对照，\n可以导出双语文本；原文件保持完整。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            Button("选择文件", action: store.chooseDocument).buttonStyle(.borderedProminent).tint(accent).disabled(isWorking)
            Text("未收藏、未导出的内容会在关闭文件或退出后清除。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }

    private var importProgress: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("正在读取文件与识别文字…").font(.callout)
                ProgressView(value: store.importProgress, total: 1).tint(accent)
            }
            Button("取消", action: store.cancelDocument)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var documentToolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Picker("方向", selection: $settings.direction) {
                    ForEach(TranslationDirection.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: 260).disabled(isWorking)
                Picker("风格", selection: $settings.style) {
                    ForEach(WritingStyle.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: 170).disabled(isWorking)
                Spacer(minLength: 0)
                if store.documentBusy {
                    ProgressView().controlSize(.small)
                    Button("停止", action: store.cancelDocument)
                } else {
                    Button(selected?.isComplete == true ? "重译所选段落" : "翻译所选段落") {
                        if let id = selected?.id { store.translateDocument(onlyID: id) }
                    }.disabled(selected == nil || isWorking)
                    Button("按当前设置翻译 \(remaining) 段") { store.translateDocument() }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(remaining == 0 || isWorking)
                }
            }
            HStack(spacing: 12) {
                ProgressView(value: Double(store.completedSegments), total: Double(max(1, store.documentRows.count)))
                    .tint(accent).frame(maxWidth: 200)
                Text("\(store.completedSegments) / \(store.documentRows.count) 段已完成").font(.caption).foregroundStyle(.secondary)
                if store.failedSegments > 0 {
                    Text("\(store.failedSegments) 段待重试").font(.caption).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var warnings: some View {
        DisclosureGroup(isExpanded: $warningsExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(store.documentWarnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.vertical, 6)
            }
            .frame(maxHeight: 140)
        } label: {
            Label("\(store.documentWarnings.count) 条导入提示 · 展开查看识别与排版说明", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private var paragraphList: some View {
        List(selection: $store.selectedSegmentID) {
            ForEach(store.documentRows) { row in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(row.segment.label).font(.caption.weight(.medium))
                        Spacer(minLength: 5)
                        if row.isBusy { ProgressView().controlSize(.mini) }
                        else if row.isComplete {
                            Image(systemName: usesCurrentSettings(row) ? "checkmark.circle.fill" : "arrow.clockwise.circle")
                                .foregroundStyle(usesCurrentSettings(row) ? accent : Color.orange)
                                .help(usesCurrentSettings(row) ? "已按当前设置翻译" : "设置已变更，可以重新翻译")
                        }
                        else if row.error != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    }
                    Text(row.segment.source).font(.callout).lineLimit(3).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6).tag(row.id)
                .contextMenu {
                    Button("复制原文") { store.copy(row.segment.source) }
                    Button("复制译文") { store.copy(row.translation) }.disabled(row.translation.isEmpty)
                    Button("收藏这一段") { store.saveFavorite(original: row.segment.source, translated: row.translation) }
                        .disabled(!row.isComplete)
                    Divider()
                    Button(row.isComplete ? "重新翻译" : "翻译这一段") { store.translateDocument(onlyID: row.id) }.disabled(isWorking)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var paragraphDetail: some View {
        if let row = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(row.segment.label).font(.headline)
                        Spacer()
                        Button { store.saveFavorite(original: row.segment.source, translated: row.translation) } label: {
                            Label("收藏", systemImage: "star")
                        }.disabled(!row.isComplete)
                    }
                    if let request = row.request {
                        Text("本段译文：\(request.direction.title) · \(request.style.title) · 术语表 \(request.glossary.count) 条")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !row.translation.isEmpty && !usesCurrentSettings(row) {
                        Label("当前设置已变更。这一段保留的是原设置下的译文，重新翻译后会应用当前设置。", systemImage: "arrow.clockwise.circle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            sourceCard(row).frame(minWidth: 240, maxWidth: .infinity)
                            resultCard(row).frame(minWidth: 240, maxWidth: .infinity)
                        }
                        VStack(alignment: .leading, spacing: 18) { sourceCard(row); resultCard(row) }
                    }
                    if let error = row.error {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button("重试这一段") { store.translateDocument(onlyID: row.id) }.disabled(isWorking)
                        }
                    }
                }.padding(22)
            }
        } else {
            Text("选择左侧段落，查看原文与译文。").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sourceCard(_ row: DocumentRow) -> some View {
        documentCard(title: "原文", text: row.segment.source, placeholder: "", working: false)
    }

    private func resultCard(_ row: DocumentRow) -> some View {
        documentCard(title: "译文", text: row.translation,
                     placeholder: row.isBusy ? "正在翻译…" : "点击「翻译所选段落」，或一次翻译剩余内容。", working: row.isBusy)
    }

    private func documentCard(title: String, text: String, placeholder: String, working: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if working { ProgressView().controlSize(.mini) }
                Spacer()
                Button { store.copy(text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("复制\(title)").disabled(text.isEmpty)
            }
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: settings.fontSize)).lineSpacing(7)
                .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(store.documentRunLabel.isEmpty ? "按当前方向与风格翻译" : store.documentRunLabel)
            Spacer()
            if store.documentUsage.totalTokens > 0 { Text(AppStore.describeUsage(store.documentUsage)) }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isWorking, let provider = providers.first, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }
        guard providers.count == 1 else { store.errorMessage = "一次请导入一个文件。"; return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let value = item as? URL { url = value }
            else { url = nil }
            Task { @MainActor in
                guard let url, url.isFileURL else { store.errorMessage = "无法读取拖入的文件，请使用「导入文件」。"; return }
                store.importDocument(url)
            }
        }
        return true
    }
}
