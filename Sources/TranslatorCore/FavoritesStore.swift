import Foundation
import Combine

public struct FavoriteItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var original: String
    public var result: String
    public var context: String
    public var mode: TranslationMode
    public var tags: [String]

    public init(id: UUID = UUID(), createdAt: Date = Date(), original: String, result: String,
                context: String = "", mode: TranslationMode = .translate, tags: [String] = []) {
        self.id = id; self.createdAt = createdAt; self.original = original; self.result = result
        self.context = context; self.mode = mode; self.tags = tags
    }
}

@MainActor
public final class FavoritesStore: ObservableObject {
    @Published public private(set) var items: [FavoriteItem] = []
    @Published public private(set) var loadError: String?
    private let url: URL
    private var canWrite = true

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YiDuTranslator/favorites.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            let data = try Data(contentsOf: self.url)
            items = try JSONDecoder().decode([FavoriteItem].self, from: data)
        } catch {
            canWrite = false
            loadError = "收藏文件暂时无法读取，已保留原文件。请在 Finder 中备份并检查收藏文件后重启应用。"
        }
    }

    public var storageURL: URL { url }

    public func add(_ item: FavoriteItem) throws {
        guard !items.contains(where: { $0.original == item.original && $0.result == item.result && $0.context == item.context }) else {
            throw TranslatorError("这条内容已经收藏。")
        }
        try commit([item] + items)
    }

    public func remove(id: UUID) throws { try commit(items.filter { $0.id != id }) }

    public func updateTags(id: UUID, text: String) throws {
        var revised = items
        guard let index = revised.firstIndex(where: { $0.id == id }) else { return }
        revised[index].tags = Array(Set(text.components(separatedBy: CharacterSet(charactersIn: ",，;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        try commit(revised)
    }

    private func commit(_ revised: [FavoriteItem]) throws {
        guard canWrite else { throw TranslatorError(loadError ?? "收藏文件无法写入。") }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(revised).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            items = revised
        } catch let error as TranslatorError { throw error }
        catch { throw TranslatorError("收藏保存失败，请检查磁盘空间与文件夹权限。原有收藏没有被替换。") }
    }

    public static func csv(_ items: [FavoriteItem]) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = items.map {
            [$0.original, $0.result, $0.context, $0.mode.title, $0.tags.joined(separator: "; "), formatter.string(from: $0.createdAt)]
                .map(csvCell).joined(separator: ",")
        }
        return "\u{FEFF}原文,释义或译文,原句,类型,标签,收藏日期\r\n" + rows.joined(separator: "\r\n") + "\r\n"
    }

    static func csvCell(_ value: String) -> String {
        // Spreadsheet applications must display translated content, not evaluate it as a formula.
        var text = value
        if let first = value.drop(while: { $0.isWhitespace }).first, "=+-@".contains(first) {
            text = "'" + value
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
