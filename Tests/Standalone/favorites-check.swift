import Foundation

@main struct FavoritesCheck {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yidu-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("favorites.json")
        let store = FavoritesStore(url: url)
        precondition(!FileManager.default.fileExists(atPath: directory.path))
        let item = FavoriteItem(original: "opportunity cost", result: "机会成本", context: "A decision.", mode: .dictionary)
        try store.add(item)
        precondition(FavoritesStore(url: url).items == [item])
        do { try store.add(item); fatalError("duplicate accepted") } catch {}
        try store.updateTags(id: item.id, text: "经济，雅思,经济")
        precondition(Set(FavoritesStore(url: url).items[0].tags) == Set(["经济", "雅思"]))
        try store.remove(id: item.id)
        precondition(FavoritesStore(url: url).items.isEmpty)
        let broken = Data("broken-data".utf8)
        try broken.write(to: url)
        let corrupt = FavoritesStore(url: url)
        precondition(corrupt.loadError != nil)
        do { try corrupt.add(item); fatalError("corrupt overwritten") } catch {}
        let original = try Data(contentsOf: url)
        precondition(original == broken)
        let csv = FavoritesStore.csv([FavoriteItem(original: "=1+1", result: "a,\"b\"\n中文")])
        precondition(csv.hasPrefix("\u{FEFF}"))
        precondition(csv.contains("\"'=1+1\""))
        precondition(csv.contains("\"a,\"\"b\"\"\n中文\""))
        print("Favorites checks: 10 passed")
    }
}
