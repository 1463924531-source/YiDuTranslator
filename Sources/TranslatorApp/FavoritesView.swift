import AppKit
import SwiftUI
import TranslatorCore

@MainActor
struct FavoritesView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var favorites: FavoritesStore
    @State private var search = ""
    @State private var selectedID: UUID?
    @State private var tagsDraft = ""
    @State private var deletingID: UUID?
    @State private var confirmDelete = false
    private let accent = AppTheme.accent

    private var filtered: [FavoriteItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return favorites.items }
        return favorites.items.filter {
            [$0.original, $0.result, $0.context, $0.tags.joined(separator: " ")].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    private var selected: FavoriteItem? { filtered.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = favorites.loadError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 24).padding(.bottom, 16).textSelection(.enabled)
            }
            Divider()
            if favorites.items.isEmpty {
                emptyState
            } else {
                HSplitView {
                    list.frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                    detail.frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reconcileSelection)
        .onChange(of: search) { _ in reconcileSelection() }
        .onChange(of: favorites.items) { _ in reconcileSelection() }
        .onChange(of: selectedID) { _ in tagsDraft = selected?.tags.joined(separator: ", ") ?? "" }
        .alert("删除这条收藏？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) { deletingID = nil }
            Button("删除", role: .destructive, action: deleteFavorite)
        } message: { Text("这条收藏及其标签会从本机删除。") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("我的收藏").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("留住值得再读的词句。共 \(favorites.items.count) 条收藏。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("导出当前搜索结果（\(filtered.count) 条）") { store.exportFavorites(filtered) }.disabled(filtered.isEmpty)
                        Divider()
                    }
                    Button("导出全部收藏（\(favorites.items.count) 条）") { store.exportFavorites(favorites.items) }
                        .disabled(favorites.items.isEmpty)
                } label: { Label("导出 CSV", systemImage: "square.and.arrow.up") }
                .fixedSize().disabled(favorites.items.isEmpty)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索原文、译文或标签", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                }
            }
            .padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }.padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "star").font(.system(size: 44, weight: .light)).foregroundStyle(accent)
            Text("从一句有用的表达开始").font(.title2.weight(.medium))
            Text("查词、翻译或文件阅读后，点击「收藏」保存内容。\n只有你主动收藏的内容会留在这里。")
                .foregroundStyle(.secondary).lineSpacing(5).multilineTextAlignment(.center)
            Button("去翻译台") { store.section = .translation }.buttonStyle(.borderedProminent).tint(accent)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack { Text("\(filtered.count) 条").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 16).padding(.vertical, 10)
            List(selection: $selectedID) {
                ForEach(filtered) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(item.mode.title).font(.caption).foregroundStyle(accent)
                            Spacer()
                            Text(item.createdAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(item.original).font(.body.weight(.medium)).lineLimit(2)
                        Text(item.result).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        if !item.tags.isEmpty { Text(item.tags.map { "#" + $0 }.joined(separator: "  ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .padding(.vertical, 7).tag(item.id)
                    .contextMenu {
                        Button("复制原文") { store.copy(item.original) }
                        Button("复制译文") { store.copy(item.result) }
                        Divider()
                        Button("删除收藏", role: .destructive) { requestDelete(item.id) }
                    }
                }
            }.listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Label(item.mode.title, systemImage: "star.fill").foregroundStyle(accent)
                        Spacer()
                        Button { requestDelete(item.id) } label: { Image(systemName: "trash") }.help("删除这条收藏")
                    }
                    textBlock("原文", text: item.original)
                    textBlock("释义 / 译文", text: item.result)
                    if !item.context.isEmpty { textBlock("收藏时的上下文", text: item.context) }
                    HStack(spacing: 12) {
                        Button { store.speak(item.original) } label: { Label("朗读原文", systemImage: "speaker.wave.2") }
                        Button("停止朗读", action: store.stopSpeaking)
                        Spacer()
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        Text("标签").font(.headline)
                        HStack {
                            TextField("例如：雅思阅读, 计算机科学", text: $tagsDraft).textFieldStyle(.roundedBorder).onSubmit(saveTags)
                            Button("保存标签", action: saveTags).disabled(tagsDraft == item.tags.joined(separator: ", "))
                        }
                        Text("用逗号分隔，点击保存后生效。").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("收藏于 \(item.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }.padding(26)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: filtered.isEmpty ? "magnifyingglass" : "star").font(.largeTitle).foregroundStyle(.tertiary)
                Text(filtered.isEmpty ? "没有找到匹配的收藏" : "选择一条收藏").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func textBlock(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { store.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("复制\(title)")
            }
            ReadableMarkdown(text: text, size: settings.fontSize)
        }
    }

    private func reconcileSelection() {
        if selectedID == nil || !filtered.contains(where: { $0.id == selectedID }) {
            selectedID = filtered.first?.id
            tagsDraft = selected?.tags.joined(separator: ", ") ?? ""
        }
    }

    private func saveTags() {
        guard let id = selected?.id else { return }
        do {
            try favorites.updateTags(id: id, text: tagsDraft)
            tagsDraft = selected?.tags.joined(separator: ", ") ?? ""
            store.notice = "标签已保存。"
        } catch { store.errorMessage = error.localizedDescription }
    }

    private func requestDelete(_ id: UUID) { deletingID = id; confirmDelete = true }

    private func deleteFavorite() {
        guard let id = deletingID else { return }
        do { try favorites.remove(id: id); reconcileSelection() }
        catch { store.errorMessage = error.localizedDescription }
        deletingID = nil
    }
}
