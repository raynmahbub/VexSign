//
//  UnifiedTaskPersistence.swift
//  VexSign
//
//  History persistence for the unified task center.
//

import Foundation
import OSLog
import NimbleExtensions

extension UnifiedTaskCenter {
    private func _loadHistory() {
        guard !historyLoading, !historyLoaded else { return }
        historyLoading = true
        
        Task { [weak self] in
            guard let self else { return }
            let result = await self.historyJournal.load()
            await MainActor.run {
                self.historyLoading = false
                switch result {
                case .blocked(let issue):
                    self.historyPersistenceIssue = issue
                    Logger.misc.warning("Task history unavailable; original retained and writes blocked.")
                case .loaded(let snapshots, let warning):
                    self.historyLoaded = true
                    self.historyPersistenceIssue = warning
                    if warning != nil {
                        Logger.misc.warning("Unreadable task history preserved in a recovery file.")
                    }
                    if !self.clearHistoryRequested {
                        // Live work may have started while disk IO was running.
                        let liveIDs = Set((self.tasks + self.history).map(\.id))
                        let recovered = snapshots.filter { !liveIDs.contains($0.id) }.map {
                            let task = UnifiedTask.from($0)
                            task.recoverAfterRestart()
                            return task
                        }
                        self.history = Array((self.history + recovered)
                            .sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.historyLimit))
                    }
                    self.clearHistoryRequested = false
                    self._persistHistory()
                }
            }
        }
    }

    private func _persistHistory() {
        guard historyLoaded else {
            // Retry unavailable reads on subsequent activity or device unlock.
            // Never replace a journal we have not successfully read/preserved.
            _loadHistory()
            return
        }
        pruneHistoryIcons()
        // Capture values on the main actor; no mutable UnifiedTask crosses to IO.
        let snapshots = (tasks + history).map { $0.snapshot }
        
        Task { [weak self] in
            guard let self else { return }
            let issue = await self.historyJournal.save(snapshots)
            await MainActor.run {
                if let issue {
                    self.historyPersistenceIssue = issue
                    Logger.misc.warning("Task history write failed; prior atomic journal retained.")
                } else if self.historyPersistenceIssue == .writeFailed {
                    self.historyPersistenceIssue = nil
                }
            }
        }
    }
}