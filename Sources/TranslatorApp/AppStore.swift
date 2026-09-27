import AppKit
import Combine
import Foundation
import ServiceManagement
import TranslatorCore
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable, Identifiable {
    case translation, documents, favorites, glossary, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .translation: return "翻译台"; case .documents: return "文件对照"; case .favorites: return "我的收藏"; case .glossary: return "术语表"; case .settings: return "设置" }
    }
    var symbol: String {
        switch self { case .translation: return "character.bubble"; case .documents: return "doc.on.doc"; case .favorites: return "star"; case .glossary: return "text.book.closed"; case .settings: return "slider.horizontal.3" }
    }
}

struct DocumentRow: Identifiable {
    var segment: DocumentSegment
    var translation = ""
    var error: String?
    var isBusy = false
    var isComplete = false
    var request: TranslationRequest?
    var id: UUID { segment.id }
}

@MainActor
final class AppStore: ObservableObject {
    let settings: AppSettings
    let favorites: FavoritesStore
    let client = DeepSeekClient()
    @Published var section: AppSection = .translation
    @Published var mode: TranslationMode = .translate
    @Published var input = ""
    @Published var context = ""
    @Published var result = ""
    @Published var explanation = ""
    @Published var followup = ""
    @Published var busy = false
    @Published var explaining = false
    @Published var usage: TokenUsage?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var imageData: Data?
    @Published var recognizing = false
    @Published var capturing = false
    @Published var hasKey = false
    @Published var keyDraft = ""
    @Published var keyStatus: String?
    @Published var testingKey = false
    @Published var accessibilityAllowed = false
    @Published var screenCaptureAllowed = false
    @Published var hotkeyWarnings: [String] = []
    @Published var launchAtLogin = false
    @Published var launchStatus: String?
    @Published var documentTitle = ""
    @Published var documentRows: [DocumentRow] = []
    @Published var documentWarnings: [String] = []
    @Published var sourceDocumentURL: URL?
    @Published var selectedSegmentID: UUID?
    @Published var importing = false
    @Published var importProgress = 0.0
    @Published var documentBusy = false
    @Published var documentUsage = TokenUsage()
    @Published var documentRunLabel = ""
    @Published var resultRequest: TranslationRequest?
    @Published var pinned = false
    var showMain: (() -> Void)?
    var showResult: (() -> Void)?
    var hideForCapture: (() -> Void)?
    var applyHotkeys: (() -> Void)?
    var updatePin: ((Bool) -> Void)?
    private var translationTask: Task<Void, Never>?
    private var explanationTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var keyTestTask: Task<Void, Never>?
    private var requestID = UUID()
    private var explanationID = UUID()
    private var importID = UUID()
    private var documentID = UUID()
    private var imageID = UUID()
    private var keyTestID = UUID()
    private var speech = NSSpeechSynthesizer()

    init(settings: AppSettings, favorites: FavoritesStore) {
        self.settings = settings; self.favorites = favorites
        do { hasKey = try KeychainStore.load() != nil }
        catch { keyStatus = error.localizedDescription }
        refreshPermissions()
    }

    var imagePreview: NSImage? { imageData.flatMap(NSImage.init(data:)) }
    var completedSegments: Int { documentRows.filter(\.isComplete).count }
    var failedSegments: Int { documentRows.filter { $0.error != nil }.count }
    var canTranslate: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy && !recognizing }
    var resultIsStale: Bool {
        guard let snapshot = resultRequest else { return false }
        return snapshot.text != input || snapshot.context != context || snapshot.direction != settings.direction || snapshot.style != settings.style || snapshot.glossary != settings.glossary || (snapshot.mode != mode && snapshot.mode != .imageExplain) || (snapshot.mode == .imageExplain && snapshot.imageData != imageData)
    }
    var usageDescription: String? { usage.map(Self.describeUsage) }

    static func describeUsage(_ usage: TokenUsage) -> String {
        let costs = usage.estimatedCostRange
        return "\(usage.totalTokens) tokens · 约 ¥\(String(format: "%.4f", costs.lowerBound))–\(String(format: "%.4f", costs.upperBound))"
    }

    func clearTranslation() {
        cancelTranslation(); cancelExplanation(); cancelImageRecognition()
        input = ""; context = ""; result = ""; explanation = ""; followup = ""
        imageData = nil; usage = nil; resultRequest = nil; errorMessage = nil; notice = nil; recognizing = false
    }

    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            errorMessage = "剪贴板里没有可粘贴的文字。"; return
        }
        cancelTranslation(); cancelExplanation(); cancelImageRecognition()
        input = text; imageData = nil; errorMessage = nil
    }

    func swapDirection() {
        guard !busy else { return }
        let reusableResult = !result.isEmpty && !resultIsStale && resultRequest?.mode == .translate ? result : nil
        cancelExplanation(); cancelImageRecognition()
        if settings.direction == .automatic, let reusableResult {
            settings.direction = Self.isChinese(reusableResult) ? .chineseToEnglish : .englishToChinese
        } else {
            settings.direction = settings.direction == .chineseToEnglish ? .englishToChinese : .chineseToEnglish
        }
        if let reusableResult { input = reusableResult; context = ""; imageData = nil }
    }

    func runTranslation(overrideMode: TranslationMode? = nil) {
        let chosen = overrideMode ?? mode
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty || (chosen == .imageExplain && imageData != nil) else {
            errorMessage = "先输入或粘贴文字，也可以截图。"; return
        }
        guard source.count <= 24_000 else {
            errorMessage = "一次输入请控制在 24,000 字以内，较长内容可以分段或使用文件翻译。"; return
        }
        let key: String
        do { key = try requireKey() } catch { errorMessage = error.localizedDescription; return }
        cancelTranslation(); cancelExplanation()
        result = ""; explanation = ""; usage = nil; errorMessage = nil; notice = nil
        let request = TranslationRequest(text: input, mode: chosen, direction: settings.direction,
            style: settings.style, context: context, imageData: chosen == .imageExplain ? imageData : nil,
            glossary: settings.glossary)
        resultRequest = request
        let id = UUID(); requestID = id; busy = true
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in client.stream(request: request, apiKey: key) {
                    try Task.checkCancellation()
                    guard requestID == id else { return }
                    switch event { case .delta(let text): result += text; case .usage(let value): usage = value }
                }
            } catch is CancellationError {
                if requestID == id && !result.isEmpty { notice = "已停止生成，当前结果可能不完整。" }
            } catch {
                if requestID == id { errorMessage = error.localizedDescription }
            }
            if requestID == id { busy = false; translationTask = nil }
        }
    }

    func cancelTranslation() {
        translationTask?.cancel(); translationTask = nil; busy = false
        requestID = UUID()
    }

    func stopTranslation() {
        cancelTranslation()
        if !result.isEmpty { notice = "已停止生成，当前结果可能不完整。" }
    }

    func explain() {
        guard !busy, !result.isEmpty, !resultIsStale else { return }
        let key: String
        do { key = try requireKey() } catch { errorMessage = error.localizedDescription; return }
        cancelExplanation()
        explanation = ""; explaining = true; errorMessage = nil
        let id = UUID(); explanationID = id
        let sourceSnapshot = resultRequest
        let translatedSnapshot = result
        let request = TranslationRequest(text: resultRequest?.text ?? input, mode: .explain,
            direction: settings.direction, style: settings.style, context: context,
            priorTranslation: result, question: followup, glossary: settings.glossary)
        explanationTask = Task { [weak self] in
            guard let self else { return }
            defer { if explanationID == id { explaining = false; explanationTask = nil } }
            do {
                for try await event in client.stream(request: request, apiKey: key) {
                    try Task.checkCancellation()
                    guard explanationID == id else { return }
                    guard resultRequest == sourceSnapshot, result == translatedSnapshot, !resultIsStale else {
                        explanation = ""; return
                    }
                    switch event { case .delta(let text): explanation += text; case .usage(let value): usage = value }
                }
            } catch is CancellationError {} catch {
                if explanationID == id, resultRequest == sourceSnapshot, !resultIsStale { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelExplanation() {
        explanationTask?.cancel(); explanationTask = nil; explaining = false; explanationID = UUID()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        notice = "已复制。"
    }

    func speak(_ text: String) {
        speech.stopSpeaking()
        guard !text.isEmpty else { return }
        let language = Self.isChinese(text) ? "zh" : "en"
        if let voice = NSSpeechSynthesizer.availableVoices.first(where: { voice in
            let locale = NSSpeechSynthesizer.attributes(forVoice: voice)[.localeIdentifier] as? String ?? ""
            return locale.lowercased().hasPrefix(language)
        }) {
            _ = speech.setVoice(voice)
        } else {
            _ = speech.setVoice(nil)
        }
        speech.startSpeaking(text)
    }

    private static func isChinese(_ text: String) -> Bool {
        if let language = NSLinguisticTagger.dominantLanguage(for: text) {
            if language.hasPrefix("zh") { return true }
            if language == "en" { return false }
        }
        return text.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) ||
                (0x20000...0x2EBEF).contains($0.value)
        }
    }

    func stopSpeaking() { speech.stopSpeaking() }

    func saveFavorite(original: String? = nil, translated: String? = nil) {
        let source = original ?? resultRequest?.text ?? input
        let output = translated ?? result
        guard !source.isEmpty, !output.isEmpty else { return }
        do {
            try favorites.add(FavoriteItem(original: source, result: output, context: original == nil ? (resultRequest?.context ?? context) : "",
                                           mode: original == nil ? (resultRequest?.mode ?? mode) : .translate))
            notice = "已收藏，可以在「我的收藏」里搜索和导出。"
        } catch { errorMessage = error.localizedDescription }
    }

    func handleShortcut(_ action: HotkeyAction) {
        if action == .screenshot { captureScreenshot(); return }
        var selected: String?
        var failure: String?
        if settings.selectionEnabled {
            do { selected = try SelectionReader.selectedText() }
            catch { failure = error.localizedDescription }
        }
        clearTranslation()
        mode = action == .dictionary ? .dictionary : .translate
        section = .translation
        if let selected { input = selected }
        errorMessage = failure
        if selected == nil && failure == nil { notice = settings.selectionEnabled ? "未读取到选中文字，可以直接输入或粘贴。" : "划词取词已关闭，可以直接输入或粘贴。" }
        showResult?()
        if selected != nil { runTranslation() }
    }

    func captureScreenshot() {
        guard settings.screenshotEnabled else { errorMessage = "截图功能已关闭，可以在设置中开启。"; return }
        guard !capturing else { return }
        capturing = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            hideForCapture?()
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                if let data = try await ScreenshotService.capture() {
                    clearTranslation(); mode = .translate; imageData = data; section = .translation
                    showResult?(); recognizeImage(data)
                } else { showResult?() }
            } catch is CancellationError {} catch {
                errorMessage = error.localizedDescription; showResult?()
            }
            capturing = false; refreshPermissions(); captureTask = nil
        }
    }

    func chooseImage() {
        guard settings.screenshotEnabled else { errorMessage = "截图功能已关闭，可以在设置中开启。"; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = false
        panel.message = "选择一张图片来翻译或解释"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1024 * 1024 else { throw TranslatorError("图片超过 32 MB，请缩小后导入。") }
            let data = try Data(contentsOf: url)
            clearTranslation(); imageData = data; section = .translation; recognizeImage(data)
        } catch { errorMessage = error is TranslatorError ? error.localizedDescription : "无法读取图片。" }
    }

    private func recognizeImage(_ data: Data) {
        cancelImageRecognition()
        let id = UUID(); imageID = id
        let originalInput = input
        recognizing = true
        imageTask = Task { [weak self] in
            guard let self else { return }
            defer { if imageID == id { recognizing = false; imageTask = nil } }
            do {
                let text = try await ImageOCR.recognize(data: data)
                try Task.checkCancellation()
                guard imageID == id, imageData == data, input == originalInput else { return }
                input = text
                notice = text.isEmpty ? "没有识别到文字，可点击「解释截图」。" : "已在本机识别文字。可以先校正原文，再翻译或解释截图。"
            } catch is CancellationError {} catch {
                if imageID == id, imageData == data { notice = "文字识别未完成。可以直接选择「解释截图」。" }
            }
        }
    }

    private func cancelImageRecognition() {
        imageID = UUID(); imageTask?.cancel(); imageTask = nil; recognizing = false
    }

    func removeImage() { cancelImageRecognition(); cancelExplanation(); imageData = nil }

    func chooseDocument() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "docx")!, UTType(filenameExtension: "doc")!]
        panel.message = "导入 PDF 或 Word，按段落查看原文与译文"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importDocument(url)
    }

    func importDocument(_ url: URL) {
        guard !importing && !documentBusy else { errorMessage = "请先停止当前文件任务，再导入新的文件。"; return }
        let ext = url.pathExtension.lowercased()
        guard ["pdf", "docx", "doc"].contains(ext) else { errorMessage = "请选择 PDF、DOCX 或 DOC 文件。"; return }
        section = .documents; errorMessage = nil; importing = true; importProgress = 0
        let id = UUID(); importID = id
        importTask = Task { [weak self] in
            guard let self else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let document = try await DocumentExtractor.extract(url: url) { [weak self] progress in
                    Task { @MainActor [weak self] in if self?.importID == id { self?.importProgress = progress } }
                }
                try Task.checkCancellation()
                guard importID == id else { return }
                documentTitle = document.title; documentRows = document.segments.map { DocumentRow(segment: $0) }
                sourceDocumentURL = url; documentWarnings = document.warnings; documentUsage = TokenUsage()
                selectedSegmentID = documentRows.first?.id
                documentRunLabel = ""; importing = false; importTask = nil
            } catch is CancellationError {
                if importID == id { importing = false }
            } catch {
                if importID == id { importing = false; errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelDocument() {
        documentID = UUID()
        documentTask?.cancel(); documentTask = nil; documentBusy = false
        importTask?.cancel(); importTask = nil; importing = false; importID = UUID()
        for index in documentRows.indices where documentRows[index].isBusy {
            documentRows[index].isBusy = false; documentRows[index].isComplete = false
            documentRows[index].error = "已停止，这一段尚未翻译完成。"
        }
    }

    func closeDocument() {
        cancelDocument(); documentTitle = ""; documentRows = []; documentWarnings = []
        sourceDocumentURL = nil; selectedSegmentID = nil; documentUsage = TokenUsage(); documentRunLabel = ""
    }

    func translateDocument(onlyID: UUID? = nil) {
        guard !documentBusy, !importing else { return }
        let key: String
        do { key = try requireKey() } catch { errorMessage = error.localizedDescription; return }
        let direction = settings.direction, style = settings.style, glossary = settings.glossary
        let ids = documentRows.filter { row in
            if let onlyID { return row.id == onlyID }
            return !row.isComplete || row.request?.direction != direction || row.request?.style != style || row.request?.glossary != glossary
        }.map(\.id)
        guard !ids.isEmpty else { notice = "文件已翻译完成。"; return }
        documentRunLabel = "\(direction.title) · \(style.title)"
        let runID = UUID(); documentID = runID
        documentBusy = true; errorMessage = nil
        documentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if documentID == runID { documentBusy = false; documentTask = nil; refreshDocumentRunLabel() }
            }
            for id in ids {
                if Task.isCancelled || documentID != runID { break }
                guard let index = documentRows.firstIndex(where: { $0.id == id }) else { break }
                documentRows[index].translation = ""; documentRows[index].error = nil
                documentRows[index].isBusy = true; documentRows[index].isComplete = false
                let request = TranslationRequest(text: documentRows[index].segment.source, mode: .translate,
                                                 direction: direction, style: style, glossary: glossary)
                documentRows[index].request = request
                do {
                    for try await event in client.stream(request: request, apiKey: key) {
                        try Task.checkCancellation()
                        guard documentID == runID, let current = documentRows.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                        switch event {
                        case .delta(let text): documentRows[current].translation += text
                        case .usage(let value):
                            documentUsage.inputTokens += value.inputTokens
                            documentUsage.outputTokens += value.outputTokens
                            documentUsage.cachedTokens += value.cachedTokens
                        }
                    }
                    try Task.checkCancellation()
                    guard documentID == runID else { return }
                    if let current = documentRows.firstIndex(where: { $0.id == id }) {
                        documentRows[current].isBusy = false; documentRows[current].isComplete = true
                    }
                } catch {
                    guard documentID == runID else { return }
                    if let current = documentRows.firstIndex(where: { $0.id == id }) {
                        documentRows[current].isBusy = false
                        documentRows[current].error = error is CancellationError ? "已停止，这一段尚未翻译完成。" : error.localizedDescription
                    }
                    if !(error is CancellationError) { errorMessage = "文件翻译已暂停：\(error.localizedDescription) 已完成的段落仍保留，可以重试。" }
                    break
                }
            }
        }
    }

    private func refreshDocumentRunLabel() {
        let requests = documentRows.compactMap(\.request)
        guard let first = requests.first else { documentRunLabel = ""; return }
        let mixed = requests.contains { $0.direction != first.direction || $0.style != first.style || $0.glossary != first.glossary }
        documentRunLabel = mixed ? "部分段落使用不同翻译设置；导出时逐段标注" : "\(first.direction.title) · \(first.style.title)"
    }

    func exportDocument() {
        guard !documentRows.isEmpty, !importing, !documentBusy else { return }
        let missing = documentRows.filter { !$0.isComplete }.count
        if missing > 0 {
            let alert = NSAlert(); alert.messageText = "还有 \(missing) 段未完成翻译"
            alert.informativeText = "导出的对照文本会明确标记未完成的段落。"
            alert.addButton(withTitle: "仍然导出"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var text = "\(documentTitle)\n原文与译文对照\n\(documentRunLabel)\n\n"
        if !documentWarnings.isEmpty { text += "导入提示：\n" + documentWarnings.joined(separator: "\n") + "\n\n" }
        for row in documentRows {
            text += "【\(row.segment.label)】\n原文\n\(row.segment.source)\n\n译文\n"
            if let request = row.request {
                text += "[\(request.direction.title) · \(request.style.title) · 术语表 \(request.glossary.count) 条]\n"
            }
            if row.isComplete { text += row.translation }
            else { text += "[未完成：\(row.error ?? "尚未翻译")]\n" + row.translation }
            text += "\n\n--------------------\n\n"
        }
        saveText(text, suggestedName: documentTitle + "-双语对照.txt", contentType: .plainText, protectedURL: sourceDocumentURL)
    }

    func exportFavorites(_ items: [FavoriteItem]? = nil) {
        saveText(FavoritesStore.csv(items ?? favorites.items), suggestedName: "译读收藏.csv", contentType: .commaSeparatedText)
    }

    private func saveText(_ text: String, suggestedName: String, contentType: UTType, protectedURL: URL? = nil) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [contentType]; panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL.resolvingSymlinksInPath() != protectedURL?.standardizedFileURL.resolvingSymlinksInPath() else {
            errorMessage = "请选择一个新的文件名，不能覆盖原文件。"; return
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8); notice = "已导出到 \(url.lastPathComponent)。" }
        catch { errorMessage = "导出失败，请检查目标位置的写入权限。" }
    }

    func saveKey() {
        keyTestID = UUID(); keyTestTask?.cancel(); keyTestTask = nil; testingKey = false
        do { try KeychainStore.save(keyDraft); keyDraft = ""; hasKey = true; keyStatus = "密钥已保存在 macOS 钥匙串。" }
        catch { keyStatus = error.localizedDescription }
    }

    func deleteKey() {
        keyTestID = UUID(); keyTestTask?.cancel(); keyTestTask = nil; testingKey = false
        do { try KeychainStore.delete(); hasKey = false; keyDraft = ""; keyStatus = "密钥已移除。" }
        catch { keyStatus = error.localizedDescription }
    }

    func testConnection() {
        guard !testingKey else { return }
        let key: String
        do { key = try requireKey() } catch { keyStatus = error.localizedDescription; return }
        testingKey = true; keyStatus = "正在发送一次简短测试请求…"
        let id = UUID(); keyTestID = id
        keyTestTask = Task { [weak self] in
            guard let self else { return }
            defer { if keyTestID == id { testingKey = false; keyTestTask = nil } }
            do {
                var testUsage: TokenUsage?
                for try await event in client.stream(request: TranslationRequest(text: "Hello", direction: .englishToChinese), apiKey: key) {
                    try Task.checkCancellation()
                    guard keyTestID == id else { return }
                    if case .usage(let usage) = event { testUsage = usage }
                }
                try Task.checkCancellation()
                guard keyTestID == id else { return }
                keyStatus = "连接成功 · DeepSeek V4.1 Flash" + (testUsage.map { " · \($0.totalTokens) tokens" } ?? "")
            } catch is CancellationError {} catch { if keyTestID == id { keyStatus = error.localizedDescription } }
        }
    }

    private func requireKey() throws -> String {
        guard let key = try KeychainStore.load(), !key.isEmpty else {
            hasKey = false
            throw TranslatorError("请先在「设置」中保存 DeepSeek 官方 API Key。")
        }
        hasKey = true; return key
    }

    func refreshPermissions() {
        accessibilityAllowed = SelectionReader.isTrusted
        screenCaptureAllowed = ScreenshotService.isAuthorized
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestAccessibility() { SelectionReader.requestAccess(); SelectionReader.openPermissionSettings(); refreshPermissions() }
    func requestScreenCapture() { _ = ScreenshotService.requestAccess(); ScreenshotService.openPermissionSettings(); refreshPermissions() }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshPermissions()
            launchStatus = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许译读。" : nil
        } catch { refreshPermissions(); launchStatus = "无法修改登录项，请在系统设置 → 通用 → 登录项中调整。" }
    }

    func shutdown() {
        cancelTranslation(); cancelExplanation(); cancelDocument(); cancelImageRecognition(); captureTask?.cancel()
        keyTestID = UUID(); keyTestTask?.cancel(); keyTestTask = nil; testingKey = false; stopSpeaking()
    }
}
