import AppKit
import Foundation

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
enum SelectionReader {
    static var isTrusted: Bool { false }
    static func selectedText() throws -> String? { nil }
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
        store.shutdown()
    }
}
