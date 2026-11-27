//
//  TaskCorrelationService.swift
//  VexSign
//
//  Builds the map from diagnostic operation IDs to the titles already recorded
//  by the task center. This lives in Services so the presentation layer never
//  reaches into the task-center singleton itself.
//

import Foundation

struct TaskCorrelationService {
    /// Only IDs the task center actually holds are returned. A missing ID is
    /// never replaced with a guessed title.
    func correlatedTitles() -> [String: String] {
        var names: [String: String] = [:]
        let center = UnifiedTaskCenter.shared
        for task in center.tasks + center.history {
            let keys = [task.id, task.context?.signingTaskID, task.context?.importTaskID]
            for key in keys.compactMap({ $0 }) {
                names[key] = task.title
            }
        }
        return names
    }
}
