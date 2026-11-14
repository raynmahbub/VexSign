import Foundation
import NimbleExtensions

enum TaskHistorySort: String, CaseIterable, Identifiable {
    case latest, oldest, name
    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return .localized("Latest activity")
        case .oldest: return .localized("Oldest activity")
        case .name: return .localized("App name")
        }
    }
}

enum TaskHistoryQuery {
    static func results(_ tasks: [UnifiedTask], query: String, sort: TaskHistorySort) -> [UnifiedTask] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var seen = Set<String>()
        return tasks.filter { task in
            guard seen.insert(task.id).inserted else { return false }
            let text = [task.title, task.subtitle ?? "", task.kind.title, task.phase.title,
                        task.failureStage?.title ?? "", task.errorText ?? ""].joined(separator: " ")
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
