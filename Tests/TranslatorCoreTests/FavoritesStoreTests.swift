import Foundation
import XCTest
@testable import TranslatorCore

final class FavoritesStoreTests: XCTestCase {
    @MainActor
    func testPersistenceStartsOnlyAfterExplicitFavorite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("favorites.json")
        let store = FavoritesStore(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let item = FavoriteItem(original: "opportunity cost", result: "机会成本", context: "The opportunity cost of a decision.", mode: .dictionary)
        try store.add(item)
        XCTAssertEqual(FavoritesStore(url: url).items, [item])
        XCTAssertThrowsError(try store.add(item))
        try store.updateTags(id: item.id, text: "经济，雅思,经济")
        XCTAssertEqual(Set(FavoritesStore(url: url).items[0].tags), Set(["经济", "雅思"]))
        try store.remove(id: item.id)
        XCTAssertTrue(FavoritesStore(url: url).items.isEmpty)
    }

    @MainActor
    func testCorruptStorageIsNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("favorites.json")
        let contents = Data("unreadable collection".utf8)
        try contents.write(to: url)
        let store = FavoritesStore(url: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.add(FavoriteItem(original: "test", result: "测试")))
        XCTAssertEqual(try Data(contentsOf: url), contents)
    }

    @MainActor
    func testCSVPreservesQuotesAndPreventsSpreadsheetFormulaExecution() {
        let csv = FavoritesStore.csv([FavoriteItem(original: "=1+1", result: "a,\"b\"\n中文")])
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(csv.contains("\"'=1+1\""))
        XCTAssertTrue(csv.contains("\"a,\"\"b\"\"\n中文\""))
    }
}
