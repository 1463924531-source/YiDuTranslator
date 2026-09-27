import AppKit
import SwiftUI
import TranslatorCore

@MainActor
struct GlossaryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @State private var source = ""
    @State private var target = ""
    @State private var search = ""
    private let accent = AppTheme.accent
    private var entries: [GlossaryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings.glossary.filter { query.isEmpty || $0.source.localizedCaseInsensitiveContains(query) || $0.target.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("术语表").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("为论文和专业词汇指定习惯译法。你手动添加的术语会用于之后的翻译。")
                    .foregroundStyle(.secondary)
            }.padding(24)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("原文术语").font(.caption).foregroundStyle(.secondary)
                        TextField("例如：opportunity cost", text: $source).textFieldStyle(.roundedBorder)
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 20)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("指定译法").font(.caption).foregroundStyle(.secondary)
                        TextField("例如：机会成本", text: $target).textFieldStyle(.roundedBorder).onSubmit(addEntry)
                    }
                    Button("添加术语", action: addEntry).buttonStyle(.borderedProminent).tint(accent)
                        .padding(.top, 20).disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("术语按「原文 → 指定译法」使用。需要反向译法时，可以单独添加反向条目。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24).padding(.bottom, 20)
            HStack {
                Text("\(settings.glossary.count) 个术语").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("搜索术语", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }.padding(.horizontal, 24).padding(.bottom, 12)
            Divider()
            if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.book.closed").font(.system(size: 38, weight: .light)).foregroundStyle(accent)
                    Text(settings.glossary.isEmpty ? "从一个专业术语开始" : "没有匹配的术语").font(.title3.weight(.medium))
                    Text(settings.glossary.isEmpty ? "添加后，译读会参考你的用词习惯。" : "试试其他关键词。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 16) {
                                Text(entry.source).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Text(entry.target).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                Button(role: .destructive) { settings.glossary.removeAll { $0.id == entry.id } } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.borderless).help("删除术语：\(entry.source)")
                            }
                            .padding(.vertical, 16).padding(.horizontal, 24)
                            Divider().padding(.horizontal, 24)
                        }
                    }
                }
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func addEntry() {
        let original = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !translated.isEmpty else { return }
        guard !settings.glossary.contains(where: { $0.source.caseInsensitiveCompare(original) == .orderedSame }) else {
            store.errorMessage = "这个原文术语已经存在。要更换译法，请先删除原条目。"; return
        }
        settings.glossary.append(.init(source: original, target: translated))
        source = ""; target = ""; store.notice = "术语已保存，会用于之后的翻译。"
    }
}

@MainActor
struct AppSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var favorites: FavoritesStore
    @State private var confirmRemoveKey = false
    private let accent = AppTheme.accent
    private var requestsRunning: Bool { store.busy || store.explaining || store.documentBusy || store.testingKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("设置").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("让译读适应你的阅读习惯。").foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            Form {
                apiSection
                interactionSection
                shortcutsSection
                permissionsSection
                readingSection
                privacySection
            }.formStyle(.grouped)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: store.refreshPermissions)
        .alert("移除已保存的密钥？", isPresented: $confirmRemoveKey) {
            Button("取消", role: .cancel) {}
            Button("移除密钥", role: .destructive, action: store.deleteKey)
        } message: { Text("移除后，需要重新输入 DeepSeek API Key 才能继续翻译。") }
    }

    private var apiSection: some View {
        Section {
            LabeledContent("翻译模型") {
                Text("DeepSeek V4.1 Flash").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: store.hasKey ? "checkmark.shield.fill" : "key").foregroundStyle(store.hasKey ? accent : Color.secondary)
                Text(store.hasKey ? "密钥已保存在 macOS 钥匙串" : "尚未配置 API Key").font(.callout)
                Spacer()
                Link("官方平台", destination: URL(string: "https://platform.deepseek.com")!)
            }
            SecureField(store.hasKey ? "输入新密钥以更新" : "粘贴 DeepSeek 官方 API Key", text: $store.keyDraft)
                .textFieldStyle(.roundedBorder).disabled(requestsRunning)
            HStack(spacing: 12) {
                Button(store.hasKey ? "更新密钥" : "保存密钥", action: store.saveKey)
                    .disabled(store.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || requestsRunning)
                Button(action: store.testConnection) {
                    if store.testingKey { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在测试…") } }
                    else { Text("测试连接") }
                }.disabled(!store.hasKey || requestsRunning)
                Spacer()
                Button("移除密钥", role: .destructive) { confirmRemoveKey = true }.disabled(!store.hasKey || requestsRunning)
            }
            if let status = store.keyStatus { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("连接测试会发送一条简短请求，并产生少量 API 费用。翻译及截图解释由 DeepSeek 官方服务处理。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("模型与密钥") }
    }

    private var interactionSection: some View {
        Section {
            Toggle(isOn: $settings.floatingEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("悬浮窗")
                    Text("快捷键结果显示在悬浮窗；关闭后显示在主窗口。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $settings.selectionEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("划词取词")
                    Text("按快捷键时读取选中文字。关闭后打开手动输入，不读取选区或旧剪贴板。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $settings.screenshotEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("截图与图片输入")
                    Text("使用框选截图或导入图片，识别文字并翻译、解释。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("单纯选择文字不会弹出窗口。以上开关可以分别设置。").font(.caption).foregroundStyle(.secondary)
        } header: { Text("使用方式") }
    }

    private var shortcutsSection: some View {
        Section {
            Toggle("启用全局快捷键", isOn: $settings.hotkeysEnabled)
            ShortcutSettingRow(title: "查词", choice: $settings.dictionaryShortcut).disabled(!settings.hotkeysEnabled)
            ShortcutSettingRow(title: "翻译句子", choice: $settings.translationShortcut).disabled(!settings.hotkeysEnabled)
            ShortcutSettingRow(title: "框选截图", choice: $settings.screenshotShortcut).disabled(!settings.hotkeysEnabled || !settings.screenshotEnabled)
            Text("快捷键在其他应用前台时也生效。修改后立即应用。").font(.caption).foregroundStyle(.secondary)
            Text("⌘2 / ⌘3 可能与其他应用的标签页切换冲突，可以在上方改为 ⌥⌘ 等组合。").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(store.hotkeyWarnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } header: { Text("快捷键") }
    }

    private var permissionsSection: some View {
        Section {
            permissionRow(title: "辅助功能", detail: "允许快捷键读取其他应用中的选中文字。", allowed: store.accessibilityAllowed, action: store.requestAccessibility)
            permissionRow(title: "屏幕录制", detail: "允许框选屏幕进行截图翻译。", allowed: store.screenCaptureAllowed, action: store.requestScreenCapture)
            if !store.accessibilityAllowed {
                DisclosureGroup("系统开关已打开，仍显示未允许？") {
                    Text("更新后可能需要替换旧授权：先完全退出译读，在系统权限列表中移除旧的译读条目，再重新添加「应用程序 → 译读.app」并开启权限，然后重开译读。这不会删除密钥或收藏。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("修改系统权限后，可以刷新状态。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新权限状态", action: store.refreshPermissions)
            }
        } header: { Text("系统权限") }
    }

    private func permissionRow(title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                    Text(allowed ? "已允许" : "未允许").font(.caption).foregroundStyle(allowed ? accent : Color.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(allowed ? "系统设置" : "前往授权", action: action)
        }
    }

    private var readingSection: some View {
        Section {
            Picker("默认翻译方向", selection: $settings.direction) {
                ForEach(TranslationDirection.allCases) { Text($0.title).tag($0) }
            }
            Picker("表达风格", selection: $settings.style) {
                ForEach(WritingStyle.allCases) { Text($0.title).tag($0) }
            }
            Picker("外观", selection: $settings.appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            HStack {
                Text("阅读字号")
                Slider(value: $settings.fontSize, in: 13...22, step: 1).frame(maxWidth: 260)
                Text("\(Int(settings.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 42)
            }
            Toggle("登录时自动启动", isOn: Binding(get: { store.launchAtLogin }, set: store.setLaunchAtLogin))
            if let status = store.launchStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("阅读与启动") }
    }

    private var privacySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("不自动保存查询历史", systemImage: "lock.shield").font(.callout.weight(.medium))
                Text("未收藏的原文、译文和截图仅在本次使用期间保留，退出后不恢复。主动收藏的内容、手动添加的术语和偏好设置保存在本机。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("翻译时会把本次文字或图片发送至 DeepSeek；API Key 保存在 macOS 钥匙串。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("收藏文件").foregroundStyle(.secondary)
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([favorites.storageURL]) }
                    .disabled(!FileManager.default.fileExists(atPath: favorites.storageURL.path))
            }
        } header: { Text("本地数据") }
    }
}

private struct ShortcutSettingRow: View {
    let title: String
    @Binding var choice: ShortcutChoice
    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            Picker("修饰键", selection: $choice.modifier) {
                ForEach(ShortcutModifier.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 100)
            Text("+").foregroundStyle(.secondary)
            Picker("数字键", selection: $choice.number) {
                ForEach(1...9, id: \.self) { Text(String($0)).tag($0) }
            }.labelsHidden().frame(width: 70)
            Text(choice.label).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).frame(width: 60)
        }
    }
}
