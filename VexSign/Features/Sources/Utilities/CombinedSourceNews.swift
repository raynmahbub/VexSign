//
//  CombinedSourceNews.swift
//  VexSign
//
//  News from every repository, not just the first one. Repositories publish
//  independent news feeds and may repeat an item, so the combined feed keeps one
//  entry per identifier and orders by publication date before display reverses it.
//

import Foundation
import AltSourceKit

enum CombinedSourceNews {
    /// Oldest-to-newest: `SourceNewsView` reverses the array for its card strip,
    /// so the latest story appears at the leading edge.
    static func items(from sources: [ASRepository], limit: Int = 12) -> [ASRepository.News] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        let unique = sources.compactMap(\.news).flatMap { $0 }
            .filter { seen.insert($0.id).inserted }
        return Array(unique.sorted { lhs, rhs in
            let left = lhs.date?.date ?? .distantPast
            let right = rhs.date?.date ?? .distantPast
            if left == right { return lhs.id < rhs.id }
            return left < right
        }.suffix(limit))
    }
}
