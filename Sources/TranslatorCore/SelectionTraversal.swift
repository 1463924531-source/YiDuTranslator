import Foundation

struct SelectionContext<Node> {
    let processID: Int32
    let window: Node
    let focus: Node?
}

/// Keeps traversal and selection extraction testable without granting a test runner AX access.
@MainActor
protocol SelectionProviding: AnyObject {
    associatedtype Node
    associatedtype Marker
    var hasTime: Bool { get }
    func snapshot() throws -> SelectionContext<Node>?
    func isCurrent(_ context: SelectionContext<Node>) throws -> Bool
    func same(_ lhs: Node, _ rhs: Node) -> Bool
    func string(_ attribute: String, _ node: Node) throws -> String?
    func flag(_ attribute: String, _ node: Node) throws -> Bool?
    func node(_ attribute: String, _ node: Node) throws -> Node?
    func children(_ node: Node, offset: Int, count: Int) throws -> [Node]
    func selectedRange(_ node: Node) throws -> CFRange?
    func characterCount(_ node: Node) throws -> Int?
    func selectedMarker(_ node: Node) throws -> Marker?
    func text(_ range: CFRange, _ node: Node) throws -> String?
    func text(_ marker: Marker, _ node: Node) throws -> String?
}

@MainActor
struct SelectionResolver<Provider: SelectionProviding> {
    let provider: Provider
    private enum Probe { case text(String), nativeCaret, empty }
    func resolve() throws -> String? {
        guard let context = try provider.snapshot(), provider.hasTime else { return nil }
        var ancestors: [Provider.Node] = []
        var preflightNodeCount = 0
        var cursor = context.focus
        var reachedWindow = context.focus == nil
        // Preflight the whole bounded focus chain before reading any text. In particular,
        // a secure parent must not be bypassed by reading an ancestor's web selection.
        while let node = cursor {
            guard provider.hasTime, ancestors.count < 24,
                  !ancestors.contains(where: { provider.same($0, node) }),
                  try !excluded(node) else { return nil }
            preflightNodeCount += 1
            if try provider.string("AXRole", node) == "AXApplication" { break }
            ancestors.append(node)
            if provider.same(node, context.window) { reachedWindow = true; break }
            cursor = try provider.node("AXParent", node)
        }
        if !reachedWindow {
            guard let focus = context.focus, let window = try provider.node("AXWindow", focus),
                  provider.same(window, context.window) else { return nil }
            // Some native controls provide AXWindow but no AXParent. Only probe
            // that control, never an unverified application-level ancestor.
            ancestors = [focus]
        }
        for node in ancestors {
            switch try probe(node) {
            case .text(let text): return try finish(text, context)
            case .nativeCaret: return nil
            case .empty: break
            }
        }
        if let focus = context.focus,
           let role = try provider.string("AXRole", focus),
           !["AXGroup", "AXScrollArea", "AXWebArea", "AXWindow", "AXSplitGroup", "AXLayoutArea", "AXApplication"].contains(role) {
            return nil
        }
        // Only this window is searched; never AXWindows or an application-wide tree.
        var queue: [(Provider.Node, Int)] = [(context.window, 0)]
        var visited: [Provider.Node] = []
        let nodeLimit = 128 - preflightNodeCount
        var index = 0
        var found: String?
        while index < queue.count, visited.count < nodeLimit, provider.hasTime {
            let (node, depth) = queue[index]; index += 1
            if visited.contains(where: { provider.same($0, node) }) { continue }
            visited.append(node)
            if try excluded(node) { continue }
            if try provider.string("AXRole", node) == "AXWebArea", case .text(let text) = try probe(node) {
                if let found, found != text { return nil }
                found = text
                // The web area's selection covers its document. Do not spend the
                // deadline scanning every paragraph after finding it.
                continue
            }
            guard depth < 8 else { continue }
            var offset = 0
            while queue.count < nodeLimit, provider.hasTime {
                let count = min(32, nodeLimit - queue.count)
                let children = try provider.children(node, offset: offset, count: count)
                queue.append(contentsOf: children.map { ($0, depth + 1) })
                if children.count < count { break }
                offset += children.count
            }
        }
        guard let found else { return nil }
        return try finish(found, context)
    }

    private func excluded(_ node: Provider.Node) throws -> Bool {
        try provider.flag("AXHidden", node) == true || provider.flag("AXProtectedContent", node) == true
            || provider.string("AXSubrole", node) == "AXSecureTextField"
            || provider.string("AXRole", node) == "AXSecureTextField"
    }

    private func probe(_ node: Provider.Node) throws -> Probe {
        guard provider.hasTime else { return .empty }
        let role = try provider.string("AXRole", node)
        let native = role == "AXTextField" || role == "AXTextArea"
        let range = try provider.selectedRange(node)
        // A caret in an editable control is authoritative. Do not resurrect an old
        // selection retained by a neighbouring web area.
        if native, let range, range.length == 0 { return .nativeCaret }
        if let text = clean(try provider.string("AXSelectedText", node)) { return .text(text) }
        if let range, range.location >= 0, range.length > 0, range.length <= 24_000 {
            if let text = clean(try provider.text(range, node)) { return .text(text) }
            if native, let count = try provider.characterCount(node), count >= 0, count <= 100_000,
               range.location <= count, range.length <= count - range.location,
               let value = try provider.string("AXValue", node), value.utf16.count <= 100_000,
               let text = clean(SelectionReader.selectedSubstring(in: value, range: range)) { return .text(text) }
        }
        if let marker = try provider.selectedMarker(node), let text = clean(try provider.text(marker, node)) {
            return .text(text)
        }
        return .empty
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func finish(_ text: String, _ context: SelectionContext<Provider.Node>) throws -> String? {
        guard provider.hasTime, try provider.isCurrent(context), provider.hasTime else { return nil }
        return text
    }
}
