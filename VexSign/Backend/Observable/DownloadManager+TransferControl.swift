//
//  DownloadManager+TransferControl.swift
//  VexSign
//
//  Network policy and transfer lifecycle: which downloads may start, and pausing,
//  cancelling, resuming and completing them.
//
//  Split out of `DownloadManager.swift` along a boundary the file already had.
//  Everything here is gated by `networkPolicyAllowsStarting` and the download
//  slots; nothing here parses a package or registers an import. The bodies are
//  unchanged — the audit asks for splits along existing responsibilities with
//  characterization tests, not a rewrite.
//

import Foundation
import NimbleExtensions
import UIKit

extension DownloadManager {
fileprivate var networkPolicyAllowsStarting: Bool {
    !GameMode.isEnabled
        && (!DownloadPreferences.wifiOnly || !DownloadPreferences.isOnExpensivePath)
        && (!DownloadPreferences.chargeOnly || DownloadPreferences.isCharging)
}

@objc fileprivate func networkPolicyDidChange() {
    reconcileNetworkPolicy()
}

/// Policy-held tasks remain waiting, distinct from explicit user pauses.
func reconcileNetworkPolicy(allowed: Bool? = nil) {
    guard Thread.isMainThread else {
        DispatchQueue.main.async { self.reconcileNetworkPolicy(allowed: allowed) }
        return
    }
    let canRun = allowed ?? networkPolicyAllowsStarting
    if !canRun {
        for download in downloads where !download.isImporting && !download.isVerifying && !download.isSigning && !download.onlyArchiving && download.progress < 1 {
            if download.task?.state == .running {
                download.task?.suspend()
                download.isActive = false
                if !download.isPaused { download.isWaitingForSlot = true }
            }
        }
    } else { drainNetworkQueue() }
}

/// FIFO admission shared by new and resumed transfers. Waiting rows own suspended tasks.
/// All admission and row registration is serialized on the main queue.
func drainNetworkQueue() {
    guard Thread.isMainThread else {
        DispatchQueue.main.async { self.drainNetworkQueue() }
        return
    }
    guard !isBatchControllingDownloads, networkPolicyAllowsStarting else { return }
    let waiting = downloads.filter { $0.isWaitingForSlot && !$0.isPaused }
    let slots = max(0, DownloadPreferences.maxParallel - activeNetworkDownloads.count)
    for download in waiting.prefix(slots) {
        guard download.task?.state == .suspended else { continue }
        download.isWaitingForSlot = false
        download.isActive = true
        download.task?.resume()
    }
}

/// Release a network slot independently of the subsequent verification/import owner.
func networkTransferFinished(_ download: Download, task: URLSessionTask) {
    guard Thread.isMainThread else {
        DispatchQueue.main.async { self.networkTransferFinished(download, task: task) }
        return
    }
    guard download.task === task else { return }
    download.isActive = false
    download.isWaitingForSlot = false
    drainNetworkQueue()
}

func pauseDownload(_ download: Download) {
    if !Thread.isMainThread {
        DispatchQueue.main.async { self.pauseDownload(download) }
        return
    }
    if download.isImporting || download.isVerifying {
        guard download.importControl.pause() else { return }
        download.isPaused = true
        objectWillChange.send()
        return
    }
    guard !download.isSigning, !download.onlyArchiving else { return }
    if download.task?.state == .running { download.task?.suspend() }
    download.isWaitingForSlot = false
    download.isPaused = true
    download.isActive = false
    drainNetworkQueue()
}

func cancelDownload(_ download: Download) {
    if !Thread.isMainThread {
        DispatchQueue.main.async { self.cancelDownload(download) }
        return
    }
    if integrityDecisions.removeValue(forKey: ObjectIdentifier(download)) != nil {
        download.packageVerification.cancel()
        download.importControl.cancel()
        if let url = download.retainedPackageURL {
            download.retainedPackageURL = nil
            finishCancelledVerification(url: url, dl: download)
        }
        return
    }
    // Auto-sign is a separate owner; do not hide a still-running signer.
    guard !download.isSigning else { return }
    if download.isImporting || download.isVerifying {
        guard download.importControl.cancel() else { return }
        download.packageVerification.cancel()
        download.isPaused = false
        // Keep the row until the worker has stopped and cleaned its files.
        objectWillChange.send()
        return
    }
    download.importControl.cancel()
    download.packageVerification.cancel()
    clearRecovery(download)
		download.task?.cancel()
    download.isWaitingForSlot = false
		download.isActive = false


		DispatchQueue.main.async {
			if let index = self.downloads.firstIndex(where: { $0 === download }) {
				self.objectWillChange.send()

				// Drop from tracking so a manually stopped download leaves overall progress.
				self.allActivityDownloads.removeValue(forKey: download.id)
				self.finishedDownloadingIDs.remove(download.id)

				self.downloads.remove(at: index)
            self.drainNetworkQueue()

				let remainingActiveDownloads = self.downloads.filter {
					$0.progress > 0 && $0.progress < 1.0 && !$0.isPaused
				}

				if !remainingActiveDownloads.isEmpty && self.downloadActivity != nil {
					self.forceNextProgressUpdate()
					self.updateLiveActivity(activeDownloads: remainingActiveDownloads)
				} else {
					self.endLiveActivity()
				}

				self.releaseKeepAliveIfIdle()
			}
		}
	}
	
	/// Stops every network/import job represented by the current Live Activity.
/// Network jobs leave immediately. Imports leave only after cooperative cancellation
/// and workspace cleanup; an auto-sign run is not hidden or cancelled by this action.
	func cancelAllDownloads() {
    if !Thread.isMainThread {
        DispatchQueue.main.async { self.cancelAllDownloads() }
        return
    }
    isBatchControllingDownloads = true
    defer { isBatchControllingDownloads = false }
		let currentDownloads = downloads.filter { $0.isActive || $0.isWaitingForSlot || $0.isPaused || $0.isVerifying || $0.isImporting || $0.isSigning } + Array(integrityDecisions.values)
		for download in currentDownloads {
			cancelDownload(download)
		}
	}

	func pauseAllDownloads() {
    if !Thread.isMainThread {
        DispatchQueue.main.async { self.pauseAllDownloads() }
        return
    }
    isBatchControllingDownloads = true
    defer { isBatchControllingDownloads = false }
		let currentDownloads = downloads.filter {
			$0.isActive || $0.isWaitingForSlot || ($0.progress > 0 && $0.progress < 1.0) || $0.isVerifying || $0.isImporting || $0.isSigning
		}
		for download in currentDownloads {
			pauseDownload(download)
		}
		
		DispatchQueue.main.async {
			let activeDownloads = self.downloads.filter {
				($0.progress > 0 && $0.progress < 1.0) ||
				($0.unpackageProgress > 0 && $0.unpackageProgress < 1.0)
			}
			if !activeDownloads.isEmpty && self.downloadActivity != nil {
				self.forceNextProgressUpdate()
				self.updateLiveActivity(activeDownloads: activeDownloads)
			}
		}
	}
	
	func resumeAllDownloads() {
    if !Thread.isMainThread {
        DispatchQueue.main.async { self.resumeAllDownloads() }
        return
    }
		// Resuming is user-initiated here (button, Live Activity, Shortcut), so say why
		// nothing happened instead of leaving the button looking broken.
		guard !GameMode.isEnabled else {
			let paused = downloads.filter { $0.isPaused && $0.progress > 0 && $0.progress < 1.0 }
			if !paused.isEmpty, !isAppInBackground {
				Task { @MainActor in
					GameMode.reportBlockedInline(.localized("Resuming downloads"))
				}
			}
			return
		}

		for download in downloads where download.isPaused {
			resumeDownload(download)
		}

		if isAppInBackground && hasUnfinishedWork {
			ensureKeepAlive()
		}
	}
	
	func isManualDownload(_ string: String) -> Bool {
		return string.contains("VexSignManualDownload")
	}
	
	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}
	
	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}
	
	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}
	
	var nonManualDownloads: [Download] {
		downloads.filter { !isManualDownload($0.id) }
	}
}
