import XCTest
import AltSourceKit
@testable import VexSign

final class CombinedSourceNewsTests: XCTestCase {
    private func repository(id: String, newsIDs: [String]) throws -> ASRepository {
        let news = newsIDs.map { """
        {"identifier":"\($0)","title":"\($0)","caption":"Story \($0)"}
        """ }.joined(separator: ",")
        // ASRepository refuses a feed with no apps, so every fixture carries a
        // minimal decodable app even though these tests only assert on news.
        let json = """
        {"identifier":"\(id)","name":"\(id)","apps":[{"name":"Fixture","bundleIdentifier":"com.example.fixture","iconURL":"https://example.com/icon.png","versions":[{"version":"1.0"}]}],"news":[\(news)]}
        """
        return try JSONDecoder().decode(ASRepository.self, from: Data(json.utf8))
    }

    func testNewsFromEverySourceIsShown() throws {
        let sources = [
            try repository(id: "one", newsIDs: ["a", "b"]),
            try repository(id: "two", newsIDs: ["c"])
        ]
        let items = CombinedSourceNews.items(from: sources)
        XCTAssertEqual(items.map(\.id), ["a", "b", "c"])
    }

    func testRepeatedIdentifiersCollapseToOneItem() throws {
        let sources = [
            try repository(id: "one", newsIDs: ["a", "b"]),
            try repository(id: "two", newsIDs: ["b", "c"])
        ]
        let items = CombinedSourceNews.items(from: sources)
        XCTAssertEqual(items.map(\.id), ["a", "b", "c"])
    }

    func testLimitKeepsTheNewestItemsAfterOrdering() throws {
        let sources = [try repository(id: "one", newsIDs: ["a", "b", "c"])]
        XCTAssertEqual(CombinedSourceNews.items(from: sources, limit: 2).map(\.id), ["b", "c"])
        XCTAssertTrue(CombinedSourceNews.items(from: sources, limit: 0).isEmpty)
    }
}
