import XCTest
import AltSourceKit
@testable import VexSign

final class CombinedSourceNewsTests: XCTestCase {
    private func repository(id: String, newsIDs: [String]) throws -> ASRepository {
        let news = newsIDs.map { """
        {"identifier":"\($0)","title":"\($0)","caption":"Story \($0)"}
        """ }.joined(separator: ",")
        let json = """
        {"identifier":"\(id)","name":"\(id)","apps":[],"news":[\(news)]}
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
