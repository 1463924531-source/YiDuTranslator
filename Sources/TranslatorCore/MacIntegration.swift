import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Registers only the requested system hotkeys; it never monitors ordinary keystrokes.
@MainActor
public final class GlobalHotkeyManager {
    private static let signature: OSType = 0x59694475 // YiDu
    private var eventHandler: EventHandlerRef?
    private var hotkeys: [UInt32: EventHotKeyRef] = [:]
    private var handler: ((HotkeyAction) -> Void)?

    public init() {}

    /// Each binding succeeds or fails independently. Successful bindings stay active.
    @discardableResult
    public func register(bindings: [HotkeyBinding], handler: @escaping (HotkeyAction) -> Void) -> [String] {
        unregisterAll()
        guard !bindings.isEmpty else { return [] }
        self.handler = handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x59694475 else {
                return OSStatus(eventNotHandledErr)
            }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(context).takeUnretainedValue()
            let actionID = identifier.id
            // Carbon application event handlers run on the main event loop. Keep delivery
            // synchronous so the caller can read the source selection before activating UI.
            return MainActor.assumeIsolated {
                guard manager.hotkeys[actionID] != nil, let action = HotkeyAction(rawValue: actionID) else {
                    return OSStatus(eventNotHandledErr)
                }
                manager.handler?(action)
                return noErr
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            self.handler = nil
            return ["无法启用全局快捷键（系统错误 \(status)）。"]
        }

        var warnings: [String] = []
        var seenActions = Set<UInt32>()
        var seenKeys = Set<String>()
        for binding in bindings {
            let label = Self.label(for: binding.action)
            let key = "\(binding.keyCode):\(binding.modifiers)"
            guard seenActions.insert(binding.action.rawValue).inserted else {
                warnings.append("\(label)重复配置，只保留第一个快捷键。")
                continue
            }
            guard seenKeys.insert(key).inserted else {
                warnings.append("\(label)与另一个功能使用了相同快捷键，请修改设置。")
                continue
            }
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: binding.action.rawValue)
            let result = RegisterEventHotKey(binding.keyCode, binding.modifiers, identifier,
                                             GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
            if result == noErr, let reference {
                hotkeys[binding.action.rawValue] = reference
            } else {
                warnings.append("\(label)快捷键注册失败，可能已被系统或其他应用占用。请修改快捷键（\(result)）。")
            }
        }
        return warnings
    }

    public func unregisterAll() {
        for reference in hotkeys.values { UnregisterEventHotKey(reference) }
        hotkeys.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        handler = nil
    }

    deinit {
        for reference in hotkeys.values { UnregisterEventHotKey(reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private static func label(for action: HotkeyAction) -> String {
        switch action {
        case .dictionary: return "查词"
        case .translate: return "翻译"
        case .screenshot: return "截图解释"
        }
    }
}

@MainActor
public enum SelectionReader {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Only call in response to an explicit user action.
    public static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func openPermissionSettings() {
        PermissionSettings.open("Privacy_Accessibility")
    }

    /// Call before activating this app or opening its result window.
    /// Unsupported apps and an empty selection return nil. Clipboard contents are never read.
    public static func selectedText() throws -> String? {
        guard isTrusted else {
            throw TranslatorError("请先在系统设置 → 隐私与安全性 → 辅助功能中允许译读读取所选文字，也可以直接粘贴文字。")
        }
        return try SelectionResolver(provider: AXSelectionProvider()).resolve()
    }

    /// Capture on the synchronous shortcut stack, before opening or activating UI.
    /// The optional WPS path is explicit and never runs for another application.
    public static func prepareRequest(allowWPSCopy: Bool) throws -> SelectionReadRequest {
        guard isTrusted else {
            throw TranslatorError("请先在系统设置 → 隐私与安全性 → 辅助功能中允许译读读取所选文字，也可以直接粘贴文字。")
        }
        let provider = AXSelectionProvider()
        guard let original = try provider.snapshot() else { return SelectionReadRequest() }
        let sourceWasWPS = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == NativeWPSCopyEnvironment.bundleIdentifier
        let environment = allowWPSCopy && sourceWasWPS ? NativeWPSCopyEnvironment(context: original) : nil
        let copyEligible = try environment?.validateContext() == true
        let text = try SelectionResolver(provider: provider).resolve()
        // A timed-out AX lookup is not permission to copy. Use a fresh bounded
        // provider solely to validate the context captured before the lookup.
        guard provider.hasTime else { return SelectionReadRequest() }
        guard try AXSelectionProvider().isCurrent(original) else { throw CancellationError() }
        if copyEligible, try environment?.validateContext() != true { return SelectionReadRequest() }
        if let text { return SelectionReadRequest(directText: text) }
        guard copyEligible, let environment else { return SelectionReadRequest() }
        return SelectionReadRequest(fallback: environment)
    }

    public static func selectedText(allowWPSCopy: Bool) async throws -> String? {
        try await prepareRequest(allowWPSCopy: allowWPSCopy).resolve()
    }

    /// AX text ranges are UTF-16 offsets. Reject invalid ranges and split surrogates.
    static func selectedSubstring(in text: String, range: CFRange) -> String? {
        let units = text.utf16
        let count = units.count
        guard range.location >= 0, range.length > 0, range.location <= count,
              range.length <= count - range.location else {
            return nil
        }
        let lower = units.index(units.startIndex, offsetBy: range.location)
        let upper = units.index(lower, offsetBy: range.length)
        func isScalarBoundary(_ index: String.UTF16View.Index) -> Bool {
            guard index != units.startIndex, index != units.endIndex else { return true }
            let previous = units[units.index(before: index)]
            let next = units[index]
            return !(0xD800...0xDBFF).contains(previous) || !(0xDC00...0xDFFF).contains(next)
        }
        guard isScalarBoundary(lower), isScalarBoundary(upper) else { return nil }
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

}

/// Every IPC is bounded, including snapshot and final context validation.
@MainActor
private final class AXSelectionProvider: SelectionProviding {
    typealias Node = AXUIElement
    typealias Marker = CFTypeRef
    private let deadline = ProcessInfo.processInfo.systemUptime + 0.7
    var hasTime: Bool { ProcessInfo.processInfo.systemUptime < deadline }

    func snapshot() throws -> SelectionContext<Node>? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let focus = try node("AXFocusedUIElement", application)
        guard let window = try node("AXFocusedWindow", application) ?? focus.flatMap({ try node("AXWindow", $0) }) else { return nil }
        return SelectionContext(processID: app.processIdentifier, window: window, focus: focus)
    }
    func isCurrent(_ context: SelectionContext<Node>) throws -> Bool {
        guard hasTime, let latest = try snapshot(), latest.processID == context.processID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processID,
              same(latest.window, context.window) else { return false }
        switch (latest.focus, context.focus) {
        case (nil, nil): return true
        case let (left?, right?): return same(left, right)
        default: return false
        }
    }
    func same(_ lhs: Node, _ rhs: Node) -> Bool { CFEqual(lhs, rhs) }
    func string(_ attribute: String, _ node: Node) throws -> String? { try read(attribute, node) as? String }
    func flag(_ attribute: String, _ node: Node) throws -> Bool? { try read(attribute, node) as? Bool }
    func node(_ attribute: String, _ node: Node) throws -> Node? {
        guard let value = try read(attribute, node), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    func children(_ node: Node, offset: Int, count: Int) throws -> [Node] {
        guard prepare(node) else { return [] }
        var values: CFArray?
        try check(AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, offset, min(32, count), &values))
        return (values as? [AXUIElement]) ?? []
    }
    func selectedRange(_ node: Node) throws -> CFRange? {
        guard let raw = try read("AXSelectedTextRange", node), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }
    func characterCount(_ node: Node) throws -> Int? { (try read("AXNumberOfCharacters", node) as? NSNumber)?.intValue }
    func selectedMarker(_ node: Node) throws -> Marker? {
        guard let marker = try read("AXSelectedTextMarkerRange", node), CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID() else { return nil }
        return marker
    }
    func text(_ range: CFRange, _ node: Node) throws -> String? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        return try parameter("AXStringForRange", value, node)
    }
    func text(_ marker: Marker, _ node: Node) throws -> String? { try parameter("AXStringForTextMarkerRange", marker, node) }
    private func parameter(_ name: String, _ value: CFTypeRef, _ node: Node) throws -> String? {
        guard prepare(node) else { return nil }
        var result: CFTypeRef?
        try check(AXUIElementCopyParameterizedAttributeValue(node, name as CFString, value, &result))
        return result as? String
    }
    private func read(_ name: String, _ node: Node) throws -> CFTypeRef? {
        guard prepare(node) else { return nil }
        var value: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(node, name as CFString, &value))
        return value
    }
    private func prepare(_ node: Node) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(node, Float(min(0.07, remaining)))
        return true
    }
    private func check(_ result: AXError) throws {
        if result == .apiDisabled {
            throw TranslatorError("辅助功能访问已关闭。请在系统设置中允许译读，或手动粘贴文字。")
        }
        // Missing attributes, stale elements and unresponsive candidates can be
        // bypassed within the same deadline. No permission errors are bypassed.
    }
}

@MainActor
public enum ScreenshotService {
    private static var captureInProgress = false
    public static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Only call from an explicit permission button or other user action.
    @discardableResult
    public static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    public static func openPermissionSettings() {
        PermissionSettings.open("Privacy_ScreenCapture")
    }

    /// The caller hides its windows before calling and restores them after this returns.
    /// Escape in the system picker returns nil; task cancellation throws CancellationError.
    public static func capture() async throws -> Data? {
        try Task.checkCancellation()
        guard !captureInProgress else { throw TranslatorError("截图选择已打开，请先完成或按 Esc 取消。") }
        guard isAuthorized else {
            throw TranslatorError("请先允许译读的屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕录制。授权后可能需要退出并重新打开译读。")
        }
        captureInProgress = true
        defer { captureInProgress = false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("YiDuCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("selection.png")
        let process = CaptureProcess(executableURL: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                                     arguments: ["-i", "-x", "-t", "png", output.path])
        let status = try await process.run()
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: output.path) else {
            // The system tool produces no file on Escape (and returns either 0 or 1).
            if status == 0 || status == 1 { return nil }
            throw TranslatorError("截图未完成（系统错误 \(status)），请重试。")
        }
        guard status == 0 else { throw TranslatorError("截图失败（系统错误 \(status)），请重试。") }
        let data = try Data(contentsOf: output)
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw TranslatorError("截图文件无效，请重新选择截图区域。")
        }
        return data
    }
}

@MainActor
private enum PermissionSettings {
    static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The process is confined by the lock. Completion waits for exit before temporary-file cleanup.
final class CaptureProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Error>?
    private var cancelled = false
    private var started = false
    private var finished = false

    init(executableURL: URL, arguments: [String]) {
        process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func run() async throws -> Int32 {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(_ continuation: CheckedContinuation<Int32, Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        guard !started, !finished else {
            lock.unlock()
            continuation.resume(throwing: TranslatorError("截图进程不能重复启动。"))
            return
        }
        self.continuation = continuation
        process.terminationHandler = { [weak self] process in self?.complete(status: process.terminationStatus) }
        do {
            try process.run()
            started = true
            lock.unlock()
        } catch {
            finished = true
            self.continuation = nil
            process.terminationHandler = nil
            lock.unlock()
            continuation.resume(throwing: TranslatorError("无法启动系统截图工具：\(error.localizedDescription)"))
        }
    }

    private func complete(status: Int32) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let wasCancelled = cancelled
        process.terminationHandler = nil
        lock.unlock()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else { continuation?.resume(returning: status) }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let shouldTerminate = started && !finished && process.isRunning
        if shouldTerminate { process.terminate() }
        lock.unlock()
        guard shouldTerminate else { return }
        // Ensure cancellation also completes if the system picker ignores SIGTERM.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.started && !self.finished && self.process.isRunning {
                kill(self.process.processIdentifier, SIGKILL)
            }
            self.lock.unlock()
        }
    }
}
