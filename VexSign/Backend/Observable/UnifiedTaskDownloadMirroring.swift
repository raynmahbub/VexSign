//
//  UnifiedTaskDownloadMirroring.swift
//  VexSign
//
//  Download mirroring from DownloadManager to UnifiedTaskCenter.
//

import Foundation
import Combine
import NimbleExtensions

extension UnifiedTaskCenter {
    // MARK: - Download mirroring

    /// Downloads, imports and their signing phase already live in
    /// `DownloadManager`; mirroring them keeps one source of truth while the
    /// task center presents the unified pipeline.
    func _mirrorDownloads() {
        DownloadManager.shared.$downloads
            .receive(on: RunLoop.main)
            .sink { [weak self] downloads in
                self?._syncMirrored(downloads: downloads)
            }
            .store(in: &cancellables)
    }

    private func _syncMirrored(downloads: [Download]) {
        let activeIDs = Set(downloads.map { $0.id })

        // Drop mirrors whose download disappeared without a terminal phase.
        for (downloadID, task) in downloadMirrors where !activeIDs.contains(downloadID) {
            if !task.phase.isTerminal {
                task.phase = .completed
                _finalize(task)
            }
            downloadMirrors.removeValue(forKey: downloadID)
        }

        for download in downloads {
            let task: UnifiedTask
            if let existing = downloadMirrors[download.id] {
                task = existing
            } else {
                let isArchive = download.onlyArchiving
                task = begin(
                    kind: isArchive ? .importIPA : .download,
                    title: download.fileName,
                    subtitle: download.appDescription,
                    phase: .queued,
                    subjectID: download.id
                )
                registerRetry(task) { [weak download] in
                    guard let download else { return }
                    if let resumeData = download.resumeData, !resumeData.isEmpty {
                        DownloadManager.shared.resumeDownload(download)
                    }
                }
                downloadMirrors[download.id] = task
            }

            // Map the download's phase onto the unified pipeline.
            let newPhase: UnifiedTaskPhase
            switch download.phase {
            case .queued: newPhase = .queued
            case .downloading: newPhase = .downloading
            case .paused: newPhase = .paused
            case .verifying, .importing: newPhase = .importing
            case .signing: newPhase = .signing
            case .completed: newPhase = .completed
            }

            if newPhase.isTerminal {
                if !task.phase.isTerminal {
                    if task.kind == .importIPA { transition(task, to: .readyToSign) }
					transition(task, to: .completed)
				}
			} else if task.phase != newPhase {
				transition(task, to: newPhase, progress: download.phaseProgress)
			} else {
				update(task, progress: download.phaseProgress)
			}
		}
	}
}