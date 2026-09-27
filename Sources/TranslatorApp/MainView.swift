import SwiftUI
import TranslatorCore

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var favorites: FavoritesStore

    private var selection: Binding<AppSection?> {
        Binding(get: { store.section }, set: { if let value = $0 { store.section = value } })
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("译读").font(.system(size: 22, weight: .semibold))
                        Text("读懂，也写得自然").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 28)

                List(selection: selection) {
                    ForEach(AppSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .padding(.vertical, 6).tag(section)
                    }
                }
                .listStyle(.sidebar)
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 10) {
                    Text("选中文字，随手查译").font(.caption).foregroundStyle(.secondary)
                    shortcut("查词", keys: settings.dictionaryShortcut.label)
                    shortcut("翻译", keys: settings.translationShortcut.label)
                    if settings.screenshotEnabled { shortcut("截图", keys: settings.screenshotShortcut.label) }
                    if !store.hotkeyWarnings.isEmpty {
                        Button { store.section = .settings } label: {
                            Label("快捷键需要调整", systemImage: "exclamationmark.circle")
                        }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.orange)
                    }
                    Divider().padding(.vertical, 3)
                    HStack(spacing: 6) {
                        Circle().fill(store.hasKey ? AppTheme.accent : Color.secondary).frame(width: 6, height: 6)
                        Text(store.hasKey ? "模型密钥已保存" : "尚未连接翻译模型")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 250)
        } detail: {
            VStack(spacing: 0) {
                if store.errorMessage != nil || store.notice != nil {
                    StoreBanners().padding(.horizontal, 24).padding(.top, 18)
                }
                Group {
                    switch store.section {
                    case .translation: TranslationView(compact: false)
                    case .documents: DocumentsView()
                    case .favorites: FavoritesView()
                    case .glossary: GlossaryView()
                    case .settings: AppSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(AppTheme.background)
        }
        .tint(AppTheme.accent)
        .frame(minWidth: 1000, minHeight: 700)
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(keys).font(.system(.caption, design: .monospaced))
                .foregroundStyle(settings.hotkeysEnabled ? .primary : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}
