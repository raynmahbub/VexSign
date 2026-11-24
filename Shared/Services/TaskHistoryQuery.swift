import Foundation

/// Queries operate on immutable transfer-safe snapshots, never live mutable task models.
protocol TaskQueryItem: Sendable {
    var id: String { get }
    var title: String { get }
    var updatedAt: Date { get }
    var queryText: String { get }
}

enum TaskHistorySort: String, CaseIterable, Identifiable {
    case latest, oldest, name
    var id: String { rawValue }

}

enum TaskHistoryQuery {
    static func results<Item: TaskQueryItem>(_ tasks: [Item], query: String, sort: TaskHistorySort) -> [Item] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var seen = Set<String>()
        return tasks.filter { task in
            guard seen.insert(task.id).inserted else { return false }
            let text = task.queryText
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sorted { left, right in
            switch sort {
            case .latest:
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            case .oldest:
                if left.updatedAt != right.updatedAt { return left.updatedAt < right.updatedAt }
            case .name:
                let order = left.title.localizedStandardCompare(right.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return left.id < right.id
        }
    }
}
