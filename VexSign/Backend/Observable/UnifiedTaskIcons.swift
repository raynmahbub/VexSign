//
//  UnifiedTaskIcons.swift
//  VexSign
//
//  Icon handling for the unified task center.
//

import Foundation
import OSLog
import UIKit
import NimbleExtensions

extension UnifiedTaskCenter {
    func historyIcon(for task: UnifiedTask) -> UIImage? { iconArchive.image(for: task.id) }

    func captureHistoryIcon(_ image: UIImage, subjectID: String) {
        // The center can be initialized lazily by the first completed import.
        // Materialize its mirror before storing that import's thumbnail.
        _syncMirrored(downloads: DownloadManager.shared.downloads)
        guard let task = (tasks + history).first(where: { $0.subjectID == subjectID }) else { return }
        do {
            try iconArchive.store(image, for: task.id)
            objectWillChange.send()
        } catch {
            Logger.misc.warning("Could not save task thumbnail: \(error.localizedDescription)")
        }
    }

    func pruneHistoryIcons() {
        do { try iconArchive.prune(keeping: Set((tasks + history).map(\.id))) }
        catch { Logger.misc.warning("Could not prune task thumbnails: \(error.localizedDescription)") }
    }
}