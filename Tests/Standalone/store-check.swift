import AppKit
import Foundation

@MainActor final class NSPasteboard {
    enum PasteboardType { case string }
    static let general = NSPasteboard()
    var suppliedText: String?
    var stringReadCount = 0
    func string(forType: PasteboardType) -> String? {
        stringReadCount += 1
        return suppliedText
    }
    func clearContents() { suppliedText = nil }
    @discardableResult func setString(_ text: String, forType: PasteboardType) -> Bool {
        suppliedText = text
        return true
    }
}

@MainActor final class DeepSeekClient {
    struct Probe { var request: TranslationRequest; var continuation: AsyncThrowingStream<TranslationEvent, Error>.Continuation }
    static var probes: [Probe] = []
    func stream(request: TranslationRequest, apiKey: String) -> AsyncThrowingStream<TranslationEvent, Error> {
        AsyncThrowingStream { continuation in Self.probes.append(Probe(request: request, continuation: continuation)) }
    }
}
@MainActor enum KeychainStore {
    static var key: String? = "test-only-not-a-real-key"
    static func load() throws -> String? { key }
    static func save(_ value: String) throws { key = value }
    static func delete() throws { key = nil }
}
@MainActor struct SelectionReadRequest {
    let id: Int
    func resolve() async throws -> String? { try await SelectionReader.resolve(id: id) }
}
@MainActor enum SelectionReader {
    struct Probe {
        var id: Int
        var continuation: CheckedContinuation<String?, Never>
    }
    static var preparedFlags: [Bool] = []
    static var probes: [Probe] = []
    static var activeResolves = 0
    static var maxActiveResolves = 0
    static var isTrusted: Bool { false }
    static func selectedText() throws -> String? { nil }
    static func prepareRequest(allowWPSCopy: Bool) throws -> SelectionReadRequest {
        preparedFlags.append(allowWPSCopy)
        return SelectionReadRequest(id: preparedFlags.count)
    }
    static func resolve(id: Int) async throws -> String? {
        activeResolves += 1
        maxActiveResolves = max(maxActiveResolves, activeResolves)
        defer { activeResolves -= 1 }
        let value: String? = await withCheckedContinuation { continuation in
            probes.append(Probe(id: id, continuation: continuation))
        }
        try Task.checkCancellation()
        return value
    }
    static func requestAccess() {}
    static func openPermissionSettings() {}
}
enum ScreenshotService {
    static var isAuthorized: Bool { false }
    static func capture() async throws -> Data? { nil }
    static func requestAccess() -> Bool { false }
    static func openPermissionSettings() {}
}
@MainActor enum ImageOCR {
    static var pending: [CheckedContinuation<String, Error>] = []
    static func recognize(data: Data) async throws -> String {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}
enum DocumentExtractor {
    static func extract(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ExtractedDocument {
        throw TranslatorError("test-import-not-used")
    }
}

@main struct StoreChecks {
    @MainActor static func settle() async { for _ in 0..<30 { await Task.yield() } }
    @MainActor static func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<300 { if condition() { return }; await Task.yield() }
        precondition(condition(), "Async operation did not start")
    }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/store-check-data")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "YiDu.StoreCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let favorites = FavoritesStore(url: directory.appendingPathComponent("favorites.json"))
        let store = AppStore(settings: settings, favorites: favorites)
        settings.direction = .englishToChinese
        store.input = "Hello"
        store.result = "你好"
        store.resultRequest = TranslationRequest(text: "Hello", direction: .englishToChinese)
        store.swapDirection()
        precondition(store.input == "你好" && settings.direction == .chineseToEnglish)
        print("PASS: swap uses current translation before changing direction")

        settings.direction = .automatic
        store.input = "计算机科学"
        store.result = "Computer science"
        store.resultRequest = TranslationRequest(text: "计算机科学", direction: .automatic)
        store.swapDirection()
        precondition(store.input == "Computer science" && settings.direction == .englishToChinese)
        settings.direction = .automatic
        store.input = "Economic growth"
        store.result = "经济增长"
        store.resultRequest = TranslationRequest(text: "Economic growth", direction: .automatic)
        store.swapDirection()
        precondition(store.input == "经济增长" && settings.direction == .chineseToEnglish)
        print("PASS: automatic direction swap infers English and Chinese result language")

        store.input = "First request"; store.result = ""; store.resultRequest = nil
        store.runTranslation()
        await waitFor { DeepSeekClient.probes.count == 1 }
        DeepSeekClient.probes[0].continuation.yield(.delta("old"))
        await settle()
        store.input = "Second request"; store.runTranslation()
        await waitFor { DeepSeekClient.probes.count == 2 }
        DeepSeekClient.probes[0].continuation.finish(throwing: TranslatorError("obsolete"))
        DeepSeekClient.probes[1].continuation.yield(.delta("new"))
        await settle()
        precondition(store.busy && store.result == "new" && store.errorMessage == nil)
        DeepSeekClient.probes[1].continuation.finish()
        await settle()
        print("PASS: obsolete translation cannot change new result or error")

        store.explain()
        await waitFor { DeepSeekClient.probes.count == 3 }
        store.input = "Edited source"
        DeepSeekClient.probes[2].continuation.yield(.delta("explanation for old source"))
        await settle()
        precondition(!store.explaining && store.explanation.isEmpty)
        DeepSeekClient.probes[2].continuation.finish()
        print("PASS: explanations are discarded after source edits")

        store.clearTranslation()
        store.imageData = Data([1]); store.recognizeImage(Data([1]))
        await waitFor { ImageOCR.pending.count == 1 }
        store.removeImage()
        store.imageData = Data([2]); store.recognizeImage(Data([2]))
        await waitFor { ImageOCR.pending.count == 2 }
        ImageOCR.pending[0].resume(throwing: TranslatorError("obsolete OCR failure"))
        await settle()
        precondition(store.recognizing && store.input.isEmpty)
        ImageOCR.pending[1].resume(returning: "new OCR")
        await settle()
        precondition(!store.recognizing && store.input == "new OCR")
        store.resultRequest = TranslationRequest(text: "new OCR", mode: .imageExplain, direction: settings.direction, imageData: Data([2]))
        precondition(!store.resultIsStale)
        store.imageData = Data([3]); precondition(store.resultIsStale)
        print("PASS: OCR replacement cancellation and image result freshness")

        store.documentRows = [DocumentRow(segment: DocumentSegment(ordinal: 1, source: "Document source"))]
        store.translateDocument()
        await waitFor { DeepSeekClient.probes.count == 4 }
        DeepSeekClient.probes[3].continuation.yield(.delta("old document"))
        await settle()
        store.cancelDocument(); store.translateDocument()
        await waitFor { DeepSeekClient.probes.count == 5 }
        await settle()
        precondition(store.documentBusy && store.documentRows[0].isBusy)
        DeepSeekClient.probes[3].continuation.finish(throwing: TranslatorError("obsolete document failure"))
        DeepSeekClient.probes[4].continuation.yield(.delta("new document"))
        DeepSeekClient.probes[4].continuation.finish()
        await settle()
        precondition(store.documentRows[0].isComplete && store.documentRows[0].translation == "new document")
        precondition(store.documentRows[0].segment.source == "Document source")
        settings.style = .academic
        store.translateDocument()
        await waitFor { DeepSeekClient.probes.count == 6 }
        precondition(DeepSeekClient.probes[5].request.style == .academic)
        DeepSeekClient.probes[5].continuation.yield(.delta("academic translation"))
        DeepSeekClient.probes[5].continuation.finish()
        await settle()
        precondition(store.documentRows[0].request?.style == .academic && store.documentRows[0].isComplete)
        print("PASS: document stop/restart isolation, original preservation and changed-style retranslation")

        store.testConnection()
        await waitFor { DeepSeekClient.probes.count == 7 }
        store.deleteKey()
        DeepSeekClient.probes[6].continuation.yield(.delta("你好"))
        DeepSeekClient.probes[6].continuation.finish()
        await settle()
        precondition(store.keyStatus == "密钥已移除。" && !store.testingKey && !store.hasKey)
        precondition(!FileManager.default.fileExists(atPath: favorites.storageURL.path))
        print("PASS: removed key status cannot be overwritten; no automatic history file")

        KeychainStore.key = "test-only-not-a-real-key"
        settings.selectionEnabled = true
        settings.wpsCopyCompatibilityEnabled = true
        var shown = 0
        store.showResult = { shown += 1 }
        store.clearTranslation()
        let requestsBeforeSelection = DeepSeekClient.probes.count
        store.handleShortcut(.translate)
        precondition(SelectionReader.preparedFlags == [true], "Shortcut must snapshot WPS compatibility synchronously")
        await waitFor { SelectionReader.probes.count == 1 }
        precondition(shown == 0 && DeepSeekClient.probes.count == requestsBeforeSelection, "No window or model request during selection cleanup")
        SelectionReader.probes[0].continuation.resume(returning: "Selected from WPS")
        await waitFor { store.input == "Selected from WPS" && DeepSeekClient.probes.count == requestsBeforeSelection + 1 }
        precondition(shown == 1 && store.mode == .translate)
        DeepSeekClient.probes[requestsBeforeSelection].continuation.finish()
        await settle()
        print("PASS: shortcut waits for asynchronous selection before showing or translating")

        settings.wpsCopyCompatibilityEnabled = false
        shown = 0
        let requestsBeforeAXOnly = DeepSeekClient.probes.count
        store.handleShortcut(.dictionary)
        precondition(SelectionReader.preparedFlags == [true, false], "Disabling WPS compatibility must reach selection boundary")
        await waitFor { SelectionReader.probes.count == 2 }
        SelectionReader.probes[1].continuation.resume(returning: "resilience")
        await waitFor { store.input == "resilience" && DeepSeekClient.probes.count == requestsBeforeAXOnly + 1 }
        precondition(shown == 1 && store.mode == .dictionary && DeepSeekClient.probes[requestsBeforeAXOnly].request.mode == .dictionary)
        DeepSeekClient.probes[requestsBeforeAXOnly].continuation.finish()
        await settle()
        print("PASS: disabled WPS compatibility passes false while normal selection still works")

        settings.wpsCopyCompatibilityEnabled = true
        shown = 0
        let requestsBeforeRapid = DeepSeekClient.probes.count
        store.handleShortcut(.translate)
        await waitFor { SelectionReader.probes.count == 3 }
        store.handleShortcut(.dictionary)
        await settle()
        precondition(SelectionReader.preparedFlags == [true, false, true] && SelectionReader.probes.count == 3,
                     "Repeated shortcut must be ignored while a selection read is active")
        precondition(SelectionReader.activeResolves == 1 && shown == 0)
        SelectionReader.probes[2].continuation.resume(returning: "first selection")
        await waitFor { store.input == "first selection" && DeepSeekClient.probes.count == requestsBeforeRapid + 1 }
        precondition(shown == 1 && SelectionReader.maxActiveResolves == 1 && store.mode == .translate)
        precondition(DeepSeekClient.probes[requestsBeforeRapid].request.text == "first selection")
        DeepSeekClient.probes[requestsBeforeRapid].continuation.finish()
        await settle()
        store.handleShortcut(.dictionary)
        precondition(SelectionReader.preparedFlags == [true, false, true, true],
                     "A new shortcut must work after the prior selection finishes")
        await waitFor { SelectionReader.probes.count == 4 }
        SelectionReader.probes[3].continuation.resume(returning: "next selection")
        await waitFor { store.input == "next selection" && DeepSeekClient.probes.count == requestsBeforeRapid + 2 }
        precondition(shown == 2 && store.mode == .dictionary && SelectionReader.maxActiveResolves == 1)
        DeepSeekClient.probes[requestsBeforeRapid + 1].continuation.finish()
        await settle()
        print("PASS: repeated shortcut is ignored during a read; next shortcut works after completion")

        settings.selectionEnabled = false
        shown = 0
        store.input = "Old text must not be reused"
        let preparedBeforeOff = SelectionReader.preparedFlags.count
        let requestsBeforeOff = DeepSeekClient.probes.count
        store.handleShortcut(.translate)
        await waitFor { shown == 1 }
        precondition(SelectionReader.preparedFlags.count == preparedBeforeOff && store.input.isEmpty)
        precondition(DeepSeekClient.probes.count == requestsBeforeOff && store.notice?.contains("已关闭") == true)
        print("PASS: disabled selection opens manual input without selection or old-text reuse")

        settings.selectionEnabled = true
        shown = 0
        let requestsBeforeInvalidation = DeepSeekClient.probes.count
        store.handleShortcut(.translate)
        await waitFor { SelectionReader.probes.count == 5 }
        store.clearTranslation()
        SelectionReader.probes[4].continuation.resume(returning: "cleared selection")
        await settle()
        precondition(store.input.isEmpty && shown == 0 && DeepSeekClient.probes.count == requestsBeforeInvalidation)

        store.handleShortcut(.translate)
        await waitFor { SelectionReader.probes.count == 6 }
        store.input = "Manual replacement"
        SelectionReader.probes[5].continuation.resume(returning: "stale selection")
        await settle()
        precondition(store.input == "Manual replacement" && shown == 0 && DeepSeekClient.probes.count == requestsBeforeInvalidation)

        NSPasteboard.general.suppliedText = "Temporary WPS copy"
        let readsBeforePaste = NSPasteboard.general.stringReadCount
        store.handleShortcut(.translate)
        await waitFor { SelectionReader.probes.count == 7 }
        store.paste()
        precondition(NSPasteboard.general.stringReadCount == readsBeforePaste,
                     "Paste must not read clipboard while selection cleanup is pending")
        precondition(store.input == "Manual replacement" && store.notice?.contains("稍后粘贴") == true)
        store.paste()
        precondition(NSPasteboard.general.stringReadCount == readsBeforePaste && store.input == "Manual replacement")
        SelectionReader.probes[6].continuation.resume(returning: "cancelled selection")
        await waitFor { !store.hasPendingSelection }
        store.paste()
        precondition(NSPasteboard.general.stringReadCount == readsBeforePaste + 1 && store.input == "Temporary WPS copy")
        precondition(DeepSeekClient.probes.count == requestsBeforeInvalidation)
        print("PASS: pending paste never reads temporary clipboard; later manual paste reads once")

        store.handleShortcut(.translate)
        await waitFor { SelectionReader.probes.count == 8 }
        store.shutdown()
        SelectionReader.probes[7].continuation.resume(returning: "late after shutdown")
        await settle()
        precondition(store.input != "late after shutdown" && shown == 0 && DeepSeekClient.probes.count == requestsBeforeInvalidation)
        print("PASS: clear, manual edit, and shutdown discard delayed selection without model calls")

        settings.screenshotEnabled = true
        let captureStore = AppStore(settings: settings, favorites: favorites)
        var captureShown = 0
        captureStore.showResult = { captureShown += 1 }
        let preparedBeforeCapture = SelectionReader.preparedFlags.count
        captureStore.captureScreenshot()
        precondition(captureStore.capturing)
        captureStore.handleShortcut(.translate)
        precondition(SelectionReader.preparedFlags.count == preparedBeforeCapture && captureShown == 0,
                     "Shortcut during screenshot capture must not prepare a selection")
        captureStore.shutdown()
        await waitFor { !captureStore.capturing }
        print("PASS: screenshot capture excludes concurrent selection shortcuts")
    }
}
