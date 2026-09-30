import AppKit
import ApplicationServices
import Carbon
import Foundation

struct ClipboardRepresentation: Equatable {
    let type: String
    let data: Data
}
struct ClipboardSnapshot: Equatable {
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumItems = 32
    static let maximumTypes = 128
    let changeCount: Int
    let items: [[ClipboardRepresentation]]
    var isBounded: Bool {
        guard items.count <= Self.maximumItems else { return false }
        var bytes = 0
        var types = 0
        for item in items {
            guard !item.isEmpty, item.count <= 32 else { return false }
            for representation in item {
                guard representation.data.count <= Self.maximumBytes - bytes else { return false }
                bytes += representation.data.count
                types += 1
                if types > Self.maximumTypes { return false }
            }
        }
        return true
    }
}

/// Transaction boundary: clipboard contents, source context, copy delivery and time.
/// Tests replace these external effects; production transaction logic stays unchanged.
@MainActor
protocol WPSCopyEnvironment: AnyObject {
    var changeCount: Int { get }
    var now: TimeInterval { get }
    func validateContext() throws -> Bool
    func backup() throws -> ClipboardSnapshot?
    func postCopy() throws
    func copiedText() throws -> String?
    func restore(_ snapshot: ClipboardSnapshot, ifUnchanged count: Int) throws -> Bool
    func pause() async
}

@MainActor
final class WPSCopyTransaction {
    private static var active = false
    func run(_ environment: WPSCopyEnvironment) async throws -> String? {
        guard !Self.active else { return nil }
        Self.active = true
        defer { Self.active = false }
        try Task.checkCancellation()
        guard try environment.validateContext() else { return nil }
        let originalCount = environment.changeCount
        let saved = try environment.backup()
        guard environment.changeCount == originalCount else { throw CancellationError() }
        guard let snapshot = saved, snapshot.isBounded else {
            throw TranslatorError("为保留原剪贴板，已跳过 WPS 兼容复制：剪贴板内容超过 32 MiB、条目过多或某种格式无法备份。请手动复制后粘贴。")
        }
        guard snapshot.changeCount == originalCount, environment.changeCount == originalCount else { throw CancellationError() }
        try Task.checkCancellation()
        guard try environment.validateContext(), environment.changeCount == originalCount else { return nil }
        try environment.postCopy()
        let deadline = environment.now + 0.75
        var observedCount: Int?
        var observedAt = environment.now
        var ambiguous = false
        var interrupted = false
        // Once Copy is posted, cancellation still runs this bounded cleanup. A late
        // response must not overlap another transaction or overwrite newer content.
        while environment.now < deadline {
            do { if try !environment.validateContext() { interrupted = true } }
            catch is CancellationError { interrupted = true }
            catch { interrupted = true }
            let count = environment.changeCount
            if count != originalCount {
                if let observedCount {
                    if count != observedCount { ambiguous = true }
                } else { observedCount = count; observedAt = environment.now }
            } else if observedCount != nil { ambiguous = true }
            if let copiedCount = observedCount, !ambiguous, !interrupted,
               environment.now - observedAt >= 0.075 {
                var text: String?
                var readError: Error?
                if !Task.isCancelled {
                    do { text = try environment.copiedText() } catch { readError = error }
                }
                guard environment.changeCount == copiedCount else {
                    ambiguous = true; await environment.pause(); continue
                }
                do {
                    guard try environment.validateContext(), environment.changeCount == copiedCount else {
                        interrupted = true; await environment.pause(); continue
                    }
                } catch {
                    interrupted = true; await environment.pause(); continue
                }
                let restored = try environment.restore(snapshot, ifUnchanged: copiedCount)
                try Task.checkCancellation()
                guard restored else { return nil }
                if let readError { throw readError }
                let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned?.isEmpty == false ? cleaned : nil
            }
            await environment.pause()
        }
        if interrupted || Task.isCancelled { throw CancellationError() }
        return nil
    }
}

/// Prepared synchronously by a shortcut callback, before any app/window activation.
@MainActor
public final class SelectionReadRequest {
    private let directText: String?
    private let fallback: WPSCopyEnvironment?
    private var consumed = false
    init(directText: String? = nil, fallback: WPSCopyEnvironment? = nil) {
        self.directText = directText; self.fallback = fallback
    }
    public func resolve() async throws -> String? {
        guard !consumed else { return nil }
        consumed = true
        try Task.checkCancellation()
        if let fallback { return try await WPSCopyTransaction().run(fallback) }
        return directText
    }
}

/// WPS-only adapter. This class never clears the clipboard to detect a new copy.
/// changeCount detects intervening writes; AppKit offers neither writer identity nor
/// an atomic compare-and-swap, so restoration is deliberately best effort.
@MainActor
final class NativeWPSCopyEnvironment: WPSCopyEnvironment {
    static let bundleIdentifier = "com.kingsoft.wpsoffice.mac"
    private let context: SelectionContext<AXUIElement>
    private let pasteboard: NSPasteboard
    private var axDeadline: TimeInterval = 0
    private struct DocumentIdentity: Equatable { let title: String?; let document: String? }
    private var capturedDocument: DocumentIdentity?
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var changeCount: Int { pasteboard.changeCount }

    init(context: SelectionContext<AXUIElement>) {
        self.context = context
        self.pasteboard = .general
    }

    func validateContext() throws -> Bool {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == context.processID,
              front.bundleIdentifier == Self.bundleIdentifier else { throw CancellationError() }
        axDeadline = now + 0.2
        let application = AXUIElementCreateApplication(context.processID)
        let focus = try element("AXFocusedUIElement", application)
        let window = try element("AXFocusedWindow", application) ?? focus.flatMap { try element("AXWindow", $0) }
        guard let window, CFEqual(window, context.window) else { throw CancellationError() }
        let document = try DocumentIdentity(title: value("AXTitle", window) as? String,
                                            document: value("AXDocument", window) as? String)
        if let capturedDocument, capturedDocument != document { throw CancellationError() }
        if capturedDocument == nil { capturedDocument = document }
        switch (focus, context.focus) {
        case (nil, nil): break
        case let (current?, original?) where CFEqual(current, original): break
        default: throw CancellationError()
        }
        var cursor = focus ?? window
        var visited: [AXUIElement] = []
        let namedDocument = [document.title, document.document].compactMap { $0 }.contains {
            $0.range(of: #"\.(docx?|pdf)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let focusedDocumentWindow = focus.map { CFEqual($0, window) } == true && namedDocument
        var documentContainer = focus == nil || focusedDocumentWindow
        var reachedWindow = false
        while visited.count < 24 {
            guard !visited.contains(where: { CFEqual($0, cursor) }) else { return false }
            visited.append(cursor)
            let role = try value("AXRole", cursor) as? String
            let subrole = try value("AXSubrole", cursor) as? String
            let protected = try value("AXProtectedContent", cursor) as? Bool
            let hidden = try value("AXHidden", cursor) as? Bool
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" ||
                protected == true || hidden == true || role == "AXToolbar" { return false }
            if visited.count == 1, focus != nil {
                // Toolbar buttons, address/search fields and a known insertion caret
                // are never a reason to recover a neighbouring document selection.
                guard ["AXGroup", "AXScrollArea", "AXWebArea", "AXLayoutArea", "AXSplitGroup"].contains(role ?? "") ||
                        (role == "AXWindow" && focusedDocumentWindow) else { return false }
            }
            if ["AXScrollArea", "AXWebArea", "AXLayoutArea"].contains(role ?? "") { documentContainer = true }
            if let raw = try value("AXSelectedTextRange", cursor), CFGetTypeID(raw) == AXValueGetTypeID() {
                let rangeValue = raw as! AXValue
                var range = CFRange()
                if AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range),
                   ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? ""), range.length == 0 { return false }
            }
            if CFEqual(cursor, window) { reachedWindow = true; break }
            guard let parent = try element("AXParent", cursor) else { return false }
            cursor = parent
        }
        return reachedWindow && documentContainer && now < axDeadline
    }

    func backup() throws -> ClipboardSnapshot? {
        let start = changeCount
        let deadline = now + 0.5
        guard let items = pasteboard.pasteboardItems else {
            guard pasteboard.types?.isEmpty != false, changeCount == start else { return nil }
            return ClipboardSnapshot(changeCount: start, items: [])
        }
        guard items.count <= ClipboardSnapshot.maximumItems else { return nil }
        var saved: [[ClipboardRepresentation]] = []
        var bytes = 0
        var typeCount = 0
        for item in items {
            let types = item.types
            guard !types.isEmpty, types.count <= 32 else { return nil }
            var representations: [ClipboardRepresentation] = []
            for type in types {
                typeCount += 1
                guard typeCount <= ClipboardSnapshot.maximumTypes, changeCount == start, now < deadline,
                      let data = item.data(forType: type),
                      data.count <= ClipboardSnapshot.maximumBytes - bytes,
                      changeCount == start, now < deadline else { return nil }
                bytes += data.count
                representations.append(ClipboardRepresentation(type: type.rawValue, data: data))
            }
            saved.append(representations)
        }
        guard changeCount == start else { return nil }
        return ClipboardSnapshot(changeCount: start, items: saved)
    }

    func postCopy() throws {
        guard try validateContext(), let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            throw CancellationError()
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        down.postToPid(context.processID)
        up.postToPid(context.processID)
    }

    func copiedText() throws -> String? {
        guard let items = pasteboard.pasteboardItems, items.count <= ClipboardSnapshot.maximumItems else { return nil }
        var text: [String] = []
        var bytes = 0
        for item in items {
            guard item.types.contains(.string) else { continue }
            guard let data = item.data(forType: .string), data.count <= 128 * 1024 - bytes,
                  let value = String(data: data, encoding: .utf8) else { return nil }
            bytes += data.count
            text.append(value)
        }
        let result = text.joined(separator: "\n")
        guard result.count <= 24_000 else { return nil }
        return result
    }

    func restore(_ snapshot: ClipboardSnapshot, ifUnchanged count: Int) throws -> Bool {
        guard snapshot.isBounded else { return false }
        // Construct new items first; objects read from NSPasteboard remain bound to it
        // and cannot safely be written back as restoration objects.
        var items: [NSPasteboardItem] = []
        for representations in snapshot.items {
            let item = NSPasteboardItem()
            for representation in representations {
                guard item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type)) else { return false }
            }
            items.append(item)
        }
        guard changeCount == count, try validateContext(), changeCount == count else { return false }
        let clearedCount = pasteboard.clearContents()
        guard changeCount == clearedCount else { return false }
        if items.isEmpty { return true }
        guard pasteboard.writeObjects(items) else {
            throw TranslatorError("已完成 WPS 复制，但原剪贴板恢复失败；请检查剪贴板后重试。")
        }
        return true
    }

    func pause() async {
        // Intentionally survives Task cancellation so a posted Copy gets one bounded
        // cleanup window. No key event is resent during cleanup.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { continuation.resume() }
        }
    }

    private func element(_ name: String, _ element: AXUIElement) throws -> AXUIElement? {
        guard let raw = try value(name, element), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    private func value(_ name: String, _ element: AXUIElement) throws -> CFTypeRef? {
        let remaining = axDeadline - now
        guard remaining > 0 else { throw CancellationError() }
        AXUIElementSetMessagingTimeout(element, Float(min(0.035, remaining)))
        var result: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name as CFString, &result) {
        case .success: return result
        case .attributeUnsupported, .noValue, .notImplemented: return nil
        default: throw CancellationError()
        }
    }
}
