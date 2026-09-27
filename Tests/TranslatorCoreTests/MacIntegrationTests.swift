import Foundation
import XCTest
@testable import TranslatorCore

final class MacIntegrationTests: XCTestCase {
    @MainActor
    func testSelectionResolverRegressions() throws {
        _ = try runSelectionRegressions { passed, label in XCTAssertTrue(passed, label) }
    }

    @MainActor
    func testSelectionUsesUTF16Offsets() {
        let text = "A😀中e\u{301}Z"
        XCTAssertEqual(SelectionReader.selectedSubstring(in: text, range: CFRange(location: 1, length: 2)), "😀")
        XCTAssertEqual(SelectionReader.selectedSubstring(in: text, range: CFRange(location: 3, length: 1)), "中")
        XCTAssertEqual(SelectionReader.selectedSubstring(in: text, range: CFRange(location: 4, length: 2)), "e\u{301}")
    }

    @MainActor
    func testSelectionRejectsBrokenSurrogatesAndInvalidRanges() {
        let text = "A😀中"
        for range in [CFRange(location: 1, length: 1), CFRange(location: 2, length: 1),
                      CFRange(location: -1, length: 1), CFRange(location: 0, length: -1),
                      CFRange(location: 0, length: 0), CFRange(location: 4, length: 1),
                      CFRange(location: 1, length: Int.max), CFRange(location: Int.max, length: 1)] {
            XCTAssertNil(SelectionReader.selectedSubstring(in: text, range: range))
        }
    }

    func testProcessReturnsExitStatus() async throws {
        let process = CaptureProcess(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        let status = try await process.run()
        XCTAssertEqual(status, 0)
    }

    func testProcessLaunchFailureCompletes() async {
        let process = CaptureProcess(executableURL: URL(fileURLWithPath: "/nonexistent/yidu-test-tool"), arguments: [])
        do {
            _ = try await process.run()
            XCTFail("A missing executable must fail.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("无法启动系统截图工具"))
        }
    }

    func testProcessCancellationStopsAnActiveProcess() async throws {
        let process = CaptureProcess(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let task = Task { try await process.run() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must throw.")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }

    @MainActor
    func testAlreadyCancelledProcessDoesNotLaunch() async throws {
        let process = CaptureProcess(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let task = Task { try await process.run() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must throw before launch.")
        } catch is CancellationError { }
    }
}

@MainActor
final class FakeSelectionProvider: SelectionProviding {
    final class Node {
        let id: String
        var strings: [String: String] = [:]
        var flags: [String: Bool] = [:]
        var parent: Node?
        var window: Node?
        var children: [Node] = []
        var range: CFRange?
        var rangeText: String?
        var marker: String?
        var markerText: String?
        init(_ id: String, role: String = "AXGroup") { self.id = id; strings["AXRole"] = role }
        func add(_ child: Node) { children.append(child); child.parent = self }
    }
    typealias Marker = String
    var hasTime = true
    var context: SelectionContext<Node>?
    var validationContext: SelectionContext<Node>?
    var onSelectionRead: (() -> Void)?
    var reads: [String] = []
    var childBatchSizes: [Int] = []
    func snapshot() throws -> SelectionContext<Node>? { context }
    func isCurrent(_ context: SelectionContext<Node>) throws -> Bool {
        let latest = validationContext ?? self.context!
        return latest.processID == context.processID && latest.window === context.window && latest.focus === context.focus
    }
    func same(_ lhs: Node, _ rhs: Node) -> Bool { lhs === rhs }
    func string(_ attribute: String, _ node: Node) throws -> String? {
        reads.append(node.id + ":" + attribute)
        if attribute == "AXSelectedText", node.strings[attribute] != nil { onSelectionRead?() }
        return node.strings[attribute]
    }
    func flag(_ attribute: String, _ node: Node) throws -> Bool? { node.flags[attribute] }
    func node(_ attribute: String, _ node: Node) throws -> Node? { attribute == "AXParent" ? node.parent : node.window }
    func children(_ node: Node, offset: Int, count: Int) throws -> [Node] {
        childBatchSizes.append(count)
        return Array(node.children.dropFirst(offset).prefix(count))
    }
    func selectedRange(_ node: Node) throws -> CFRange? { node.range }
    func characterCount(_ node: Node) throws -> Int? { node.strings["AXValue"]?.utf16.count }
    func selectedMarker(_ node: Node) throws -> String? { node.marker }
    func text(_ range: CFRange, _ node: Node) throws -> String? { node.rangeText }
    func text(_ marker: String, _ node: Node) throws -> String? { node.markerText }
}

@MainActor
func runSelectionRegressions(_ check: (Bool, String) -> Void) throws -> Int {
    typealias Node = FakeSelectionProvider.Node
    var count = 0
    func verify(_ value: Bool, _ label: String) { count += 1; check(value, label) }
    func fixture(_ role: String = "AXGroup") -> (FakeSelectionProvider, Node, Node) {
        let p = FakeSelectionProvider(), w = Node("window", role: "AXWindow"), f = Node("focus", role: role)
        w.add(f); p.context = SelectionContext(processID: 1, window: w, focus: f)
        return (p, w, f)
    }
    do {
        let (p, _, f) = fixture(); let web = Node("web", role: "AXWebArea")
        web.strings["AXSelectedText"] = "A selected IELTS sentence."; f.add(web)
        verify(try SelectionResolver(provider: p).resolve() == "A selected IELTS sentence.", "focused container → webarea selection")
    }
    do {
        let (p, w, f) = fixture("AXStaticText"); let web = Node("web", role: "AXWebArea")
        w.children = []; w.add(web); web.add(f); web.marker = "opaque marker"; web.markerText = "Ancestor marker text"
        verify(try SelectionResolver(provider: p).resolve() == "Ancestor marker text", "ancestor opaque marker conversion")
    }
    do {
        let (p, w, f) = fixture("AXTextField"); f.range = CFRange(location: 2, length: 0)
        let web = Node("old-web", role: "AXWebArea"); web.strings["AXSelectedText"] = "stale selection"; w.add(web)
        verify(try SelectionResolver(provider: p).resolve() == nil && !p.reads.contains("old-web:AXSelectedText"), "native caret must not revive old web selection")
    }
    for secureKind in 0..<3 {
        let (p, w, f) = fixture(); let secure = Node("secure")
        if secureKind == 0 { secure.strings["AXSubrole"] = "AXSecureTextField" }
        if secureKind == 1 { secure.strings["AXRole"] = "AXSecureTextField" }
        if secureKind == 2 { secure.flags["AXProtectedContent"] = true }
        w.children = []; w.add(secure); secure.add(f); f.strings["AXSelectedText"] = "private"
        verify(try SelectionResolver(provider: p).resolve() == nil && !p.reads.contains("focus:AXSelectedText"), "secure ancestor preflight \(secureKind)")
    }
    do {
        let (p, _, f) = fixture(); f.parent = f; f.strings["AXSelectedText"] = "text"
        verify(try SelectionResolver(provider: p).resolve() == nil, "ancestor cycle terminates safely")
    }
    do {
        let (p, w, f) = fixture(); let hidden = Node("hidden", role: "AXWebArea"), nested = Node("nested", role: "AXWebArea")
        hidden.flags["AXHidden"] = true; nested.strings["AXSelectedText"] = "hidden selection"
        f.add(hidden); hidden.add(nested); f.children.append(w)
        verify(try SelectionResolver(provider: p).resolve() == nil && !p.reads.contains("nested:AXSelectedText"), "hidden subtree and descendant cycle")
    }
    for changed in 0..<3 {
        let (p, w, f) = fixture(); f.strings["AXSelectedText"] = "text"
        p.onSelectionRead = { p.validationContext = SelectionContext(processID: changed == 0 ? 2 : 1,
            window: changed == 1 ? Node("other-window") : w, focus: changed == 2 ? Node("other-focus") : f) }
        verify(try SelectionResolver(provider: p).resolve() == nil, "changed process/window/focus \(changed)")
    }
    do {
        let (p, _, f) = fixture("AXStaticText"); f.range = CFRange(location: 0, length: 3); f.rangeText = "文字😀"
        verify(try SelectionResolver(provider: p).resolve() == "文字😀" && !p.reads.contains("focus:AXValue"), "noneditable range parameter conversion")
    }
    do {
        let (p, _, f) = fixture("AXTextField"); f.range = CFRange(location: 1, length: 2); f.strings["AXValue"] = "A😀中"
        verify(try SelectionResolver(provider: p).resolve() == "😀", "bounded native UTF-16 value fallback")
    }
    do {
        let (p, _, f) = fixture("AXWebArea"); f.range = CFRange(location: 0, length: 4); f.strings["AXValue"] = "entire page must not be read"
        verify(try SelectionResolver(provider: p).resolve() == nil && !p.reads.contains("focus:AXValue"), "never read webpage value")
    }
    do {
        let (p, _, f) = fixture()
        for text in ["first", "second"] { let web = Node(text, role: "AXWebArea"); web.strings["AXSelectedText"] = text; f.add(web) }
        verify(try SelectionResolver(provider: p).resolve() == nil, "different web selections are ambiguous")
    }
    do {
        let (p, _, f) = fixture(); let web = Node("web", role: "AXWebArea"); web.strings["AXSelectedText"] = "selected"
        f.add(web); for index in 0..<300 { web.add(Node("paragraph\(index)")) }
        verify(try SelectionResolver(provider: p).resolve() == "selected" && !p.reads.contains(where: { $0.hasPrefix("paragraph") }), "selected webarea prunes large document")
    }
    do {
        let (p, w, f) = fixture("AXStaticText"); w.children = []; var parent = w
        for index in 0..<16 { let node = Node("ancestor\(index)"); parent.add(node); parent = node }
        parent.add(f); f.strings["AXSelectedText"] = "deep selection"
        verify(try SelectionResolver(provider: p).resolve() == "deep selection", "selection inside deeply nested web content")
    }
    do {
        let (p, w, f) = fixture("AXTextField"); f.parent = nil; f.window = w; f.strings["AXSelectedText"] = "native"
        verify(try SelectionResolver(provider: p).resolve() == "native", "native AXWindow without AXParent")
    }
    do {
        let (p, w, f) = fixture(); p.context = SelectionContext(processID: 1, window: w, focus: nil)
        let web = Node("web", role: "AXWebArea"); web.strings["AXSelectedText"] = "unfocused"; f.add(web)
        verify(try SelectionResolver(provider: p).resolve() == "unfocused", "unavailable focus searches only captured window")
    }
    do {
        let (p, _, f) = fixture(); f.strings["AXSelectedText"] = "expired"; p.onSelectionRead = { p.hasTime = false }
        verify(try SelectionResolver(provider: p).resolve() == nil, "deadline expiry rejects result")
    }
    do {
        let (p, _, f) = fixture(); for index in 0..<200 { f.add(Node("node\(index)")) }
        let result = try SelectionResolver(provider: p).resolve()
        let nodes = Set(p.reads.map { $0.split(separator: ":")[0] })
        verify(result == nil && nodes.count <= 128 && p.childBatchSizes.allSatisfy { $0 <= 32 }, "node and IPC child batch bounds")
    }
    return count
}
