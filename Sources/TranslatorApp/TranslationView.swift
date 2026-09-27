import SwiftUI
import TranslatorCore

struct FloatingTranslatorView: View {
    var body: some View { TranslationView(compact: true) }
}

struct TranslationView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var favorites: FavoritesStore
    var compact = false
    @State private var showContext = false

    private var resultIsCurrent: Bool {
        !store.resultIsStale && (store.resultRequest?.mode != .imageExplain || store.resultRequest?.imageData == store.imageData)
    }
    private var canUseResult: Bool { !store.result.isEmpty && !store.busy && resultIsCurrent }
    private var resultTitle: String {
        let mode = store.result.isEmpty ? store.mode : (store.resultRequest?.mode ?? store.mode)
        switch mode {
        case .dictionary: return "词义与用法"
        case .polish: return "润色结果"
        case .imageExplain: return "截图解释"
        default: return "译文"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            heading
            if compact { StoreBanners() }
            if !store.hasKey { connectionPrompt }
            modeBar
            optionsBar
            if compact {
                ScrollView {
                    VStack(spacing: 12) {
                        sourceCard
                        resultCard
                    }.padding(.bottom, 2)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    sourceCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                    resultCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").font(.caption)
                Text("仅在操作时发送待处理内容").font(.caption)
                Spacer()
                if let usage = store.usageDescription { Text(usage).font(.caption2).textSelection(.enabled) }
            }
            .foregroundStyle(.secondary)
        }
        .padding(compact ? 16 : 24)
        .background(AppTheme.background)
        .tint(AppTheme.accent)
        .frame(minWidth: compact ? 500 : 730, minHeight: compact ? 580 : 540)
        .onAppear { showContext = !store.context.isEmpty }
    }

    private var heading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(compact ? "译读" : "翻译台").font(.system(size: compact ? 19 : 26, weight: .semibold))
                if !compact { Text("查清词义，理解句子，写出自然表达。").font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            if compact {
                Button {
                    store.pinned.toggle(); store.updatePin?(store.pinned)
                } label: { Image(systemName: store.pinned ? "pin.fill" : "pin") }
                .buttonStyle(.borderless).foregroundStyle(store.pinned ? AppTheme.accent : Color.secondary)
                .help(store.pinned ? "取消置顶" : "保持窗口置顶")
                Button { store.showMain?() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help("打开主窗口")
            }
        }
    }

    private var connectionPrompt: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal").foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("连接你的翻译模型").font(.callout.weight(.medium))
                Text("添加 DeepSeek API Key 后即可开始。密钥保存在系统钥匙串。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("设置密钥") { store.section = .settings; store.showMain?() }
        }
        .padding(12).background(AppTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var modeBar: some View {
        HStack(spacing: 12) {
            Picker("处理方式", selection: $store.mode) {
                Text("查词").tag(TranslationMode.dictionary)
                Text("翻译").tag(TranslationMode.translate)
                Text("润色").tag(TranslationMode.polish)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? 240 : 300)
            .disabled(store.busy)
            Spacer(minLength: 0)
            Button { store.captureScreenshot() } label: { Label("截图", systemImage: "viewfinder") }
                .help("截图解释 · \(settings.screenshotShortcut.label)")
                .disabled(!settings.screenshotEnabled || store.capturing || store.busy)
            Button { store.chooseImage() } label: { Image(systemName: "photo.badge.plus") }
                .help("导入图片").accessibilityLabel("导入图片")
                .disabled(!settings.screenshotEnabled || store.recognizing || store.busy)
        }
    }

    private var optionsBar: some View {
        HStack(spacing: 8) {
            Picker("翻译方向", selection: $settings.direction) {
                ForEach(TranslationDirection.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(maxWidth: compact ? 190 : 220)
            Button { store.swapDirection() } label: { Image(systemName: "arrow.left.arrow.right") }
                .buttonStyle(.borderless).help("切换翻译方向")
            Spacer(minLength: 8)
            Picker("表达风格", selection: $settings.style) {
                ForEach(WritingStyle.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: compact ? 128 : 150)
        }
        .disabled(store.busy)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("原文", systemImage: "text.alignleft").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(store.input.count) 字").font(.caption).monospacedDigit()
                    .foregroundStyle(store.input.count > 24_000 ? Color.red : Color.secondary)
                Button { store.speak(store.input) } label: { Image(systemName: "speaker.wave.2") }
                    .buttonStyle(.borderless).help("朗读原文").accessibilityLabel("朗读原文")
                    .disabled(store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("粘贴") { store.paste() }.buttonStyle(.borderless)
                Button { store.clearTranslation() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("清空本次内容")
                    .disabled(store.input.isEmpty && store.result.isEmpty && store.imageData == nil)
            }
            if let preview = store.imagePreview {
                HStack(spacing: 10) {
                    Image(nsImage: preview).resizable().scaledToFit()
                        .frame(width: 70, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已选择图片").font(.callout.weight(.medium))
                        if store.recognizing {
                            HStack(spacing: 5) { ProgressView().controlSize(.small); Text("正在本机识别文字…").font(.caption) }
                        } else { Text("可校正下方文字，或直接解释图片").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button { store.removeImage() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("移除图片")
                        .disabled(store.busy)
                }
                .padding(10).background(AppTheme.background, in: RoundedRectangle(cornerRadius: 9))
            }
            ZStack(alignment: .topLeading) {
                if store.input.isEmpty {
                    Text(store.mode == .dictionary ? "输入一个单词，查看主要词义和用法…" : "输入或粘贴想读懂的内容…")
                        .foregroundStyle(.tertiary).font(.system(size: settings.fontSize))
                        .padding(.horizontal, 6).padding(.top, 8).allowsHitTesting(false)
                }
                TextEditor(text: $store.input)
                    .font(.system(size: settings.fontSize)).scrollContentBackground(.hidden)
                    .accessibilityLabel("原文输入框")
            }
            .frame(minHeight: compact ? 110 : 210, maxHeight: compact ? 160 : .infinity)
            .disabled(store.recognizing)

            DisclosureGroup("补充上下文", isExpanded: $showContext) {
                TextField("例如：这是论文中的一句话；bank 指河岸。", text: $store.context, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4).padding(.top, 8)
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                if store.imageData != nil {
                    Button("解释截图") { store.runTranslation(overrideMode: .imageExplain) }
                        .disabled(store.busy || store.recognizing || !store.hasKey)
                } else {
                    Text("⌘ ↵ 开始").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if store.busy {
                    ProgressView().controlSize(.small)
                    Button { store.stopTranslation() } label: { Label("停止", systemImage: "stop.fill") }
                } else {
                    Button { store.runTranslation() } label: {
                        Label(store.mode == .dictionary ? "查词" : store.mode == .polish ? "开始润色" : "开始翻译", systemImage: "arrow.right")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canTranslate || !store.hasKey || store.capturing)
                }
            }
        }
        .padding(16).modifier(SurfaceModifier())
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label(resultTitle, systemImage: "character.bubble").font(.subheadline.weight(.semibold))
                Spacer()
                if store.busy { Text("正在生成…").font(.caption).foregroundStyle(AppTheme.accent) }
                resultActions
            }
            if !resultIsCurrent && !store.result.isEmpty {
                Label("原文或选项已改变，请重新生成后再使用结果。", systemImage: "arrow.clockwise.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.result.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: store.busy ? "ellipsis.bubble" : "character.bubble")
                                .font(.system(size: 28, weight: .light)).foregroundStyle(AppTheme.accent.opacity(0.6))
                            Text(store.busy ? "正在理解原文…" : "把意思读明白").font(.headline).foregroundStyle(.secondary)
                            Text(store.busy ? "结果会逐步显示在这里。" : "译文、词义和润色建议会显示在这里。")
                                .font(.callout).foregroundStyle(.tertiary)
                        }.padding(.top, 26).frame(maxWidth: .infinity, alignment: .leading)
                    } else { ReadableMarkdown(text: store.result, size: settings.fontSize) }
                    if !store.explanation.isEmpty || store.explaining {
                        Divider()
                        HStack {
                            Label("进一步理解", systemImage: "lightbulb").font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.accent)
                            Spacer()
                            if store.explaining { ProgressView().controlSize(.small) }
                        }
                        if !store.explanation.isEmpty { ReadableMarkdown(text: store.explanation, size: settings.fontSize) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 3)
            }
            .frame(minHeight: compact ? 180 : 210, maxHeight: compact ? 280 : .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if store.explaining {
                        Button { store.cancelExplanation() } label: { Label("停止解释", systemImage: "stop.fill") }
                    } else {
                        Button { store.followup = ""; store.explain() } label: { Label("解释含义与表达", systemImage: "lightbulb") }
                            .disabled(!canUseResult)
                    }
                    Spacer()
                    Button { store.stopSpeaking() } label: { Image(systemName: "speaker.slash") }
                        .buttonStyle(.borderless).help("停止朗读")
                }
                HStack(spacing: 8) {
                    TextField("继续问：这里为什么这样译？", text: $store.followup)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canAskFollowup { store.explain() } }
                    Button { store.explain() } label: { Image(systemName: "arrow.up") }
                        .help("发送追问").accessibilityLabel("发送追问")
                        .disabled(!canAskFollowup)
                }
                .disabled(!canUseResult || store.explaining)
            }
        }
        .padding(16).modifier(SurfaceModifier())
    }

    private var canAskFollowup: Bool {
        canUseResult && !store.explaining && !store.followup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resultActions: some View {
        HStack(spacing: 12) {
            Button { store.copy(store.result) } label: { Image(systemName: "doc.on.doc") }
                .help("复制结果").accessibilityLabel("复制结果")
            Button { store.speak(store.result) } label: { Image(systemName: "speaker.wave.2") }
                .help("朗读结果").accessibilityLabel("朗读结果")
            Button { store.saveFavorite() } label: { Image(systemName: "star") }
                .help("收藏原文和结果").accessibilityLabel("收藏原文和结果")
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(!canUseResult)
    }
}
