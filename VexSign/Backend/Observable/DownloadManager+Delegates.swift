//
//  DownloadManager+Delegates.swift
//  VexSign
//

import Foundation
import Combine
import UIKit
import UserNotifications
import BackgroundTasks
import ActivityKit

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
        defer { networkTransferFinished(download, task: downloadTask) }
		
		if isAppInBackground {
			let activeDownloads = downloads.filter { $0.progress > 0 && $0.progress < 1.0 && $0.id != download.id }
			if activeDownloads.isEmpty {
				UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["merged_download_progress"])
			}
		}
		
		let customTempDir = FileManager.default.downloadStaging
		
		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)

			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			let destinationURL = DownloadStagingName.destination(in: customTempDir, suggestedFilename: suggestedFileName)

			try FileManager.default.moveItem(at: location, to: destinationURL)

			// ID-keyed so duplicates count correctly (drives the X/Y counter).
			finishedDownloadingIDs.insert(download.id)
            download.progress = 1.0

			if downloadActivity != nil {
				let activeDownloads = downloads.filter {
					($0.progress > 0 && $0.progress < 1.0 && !$0.isPaused) ||
					($0.unpackageProgress > 0 && $0.unpackageProgress < 1.0)
				}
				forceNextProgressUpdate()
				updateLiveActivity(activeDownloads: activeDownloads)
			}

			try handlePackageFile(url: destinationURL, dl: download)
		} catch {
			if isAppInBackground {
				sendCompletionNotification(for: download, status: "❌ Download failed")
			}
			
			download.isActive = false
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let download = getDownloadTask(by: downloadTask) else { return }

        let now = Date()
        let completed = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard completed || now.timeIntervalSince(download.lastProgressPublication) >= 0.2 else { return }
        download.lastProgressPublication = now

		download.bytesDownloaded = totalBytesWritten

		if totalBytesExpectedToWrite > 0 {
			download.totalBytes = totalBytesExpectedToWrite
			download.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
		} else if download.totalBytes > 0 {
			// Server returned 0; fall back to the last known total.
			download.progress = Double(totalBytesWritten) / Double(download.totalBytes)
		}

		let activeDownloads = self.downloads.filter { $0.progress > 0 && $0.progress < 1.0 && !$0.isPaused }
		if !activeDownloads.isEmpty {
			if self.isAppInBackground {
				// The manager owns a single BackgroundTaskManager while work is unfinished.
                if now.timeIntervalSince(self.lastUpdateTime) >= self.updateThrottle {
                    if self.downloadActivity != nil { self.updateLiveActivity(activeDownloads: activeDownloads) }
                    else { self.startLiveActivityIfNeeded() }
                }
			} else {
				let now = Date()
				if now.timeIntervalSince(self.lastUpdateTime) >= self.updateThrottle {
					if self.downloadActivity != nil {
						self.updateLiveActivity(activeDownloads: activeDownloads)
					} else {
						self.startLiveActivityIfNeeded()
					}
				}
			}
		}
	}
	
	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard
			let error = error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
		else {
			return
		}

        defer { networkTransferFinished(download, task: downloadTask) }

		let nsError = error as NSError

		// Cancelled — stash resume data and bail.
		if nsError.code == NSURLErrorCancelled {
			if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
				download.resumeData = resumeData
				saveResumeData(for: download)
			}
			return
		}

		// Recoverable network errors — pause for retry instead of failing.
		if nsError.code == NSURLErrorNetworkConnectionLost ||
		   nsError.code == NSURLErrorNotConnectedToInternet ||
		   nsError.code == NSURLErrorTimedOut ||
		   nsError.code == NSURLErrorDNSLookupFailed {
			download.isPaused = true
			download.isActive = false

			if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
				download.resumeData = resumeData
				saveResumeData(for: download)
			}

			sendSystemNotification(
				title: "Download paused",
				body: "\(download.fileName) - resume from Downloads when connectivity returns",
				identifier: "pause_\(download.id)"
			)

			DispatchQueue.main.async {
				let activeDownloads = self.downloads.filter {
					($0.progress > 0 && $0.progress < 1.0) ||
					($0.unpackageProgress > 0 && $0.unpackageProgress < 1.0)
				}

				if self.downloadActivity != nil && !activeDownloads.isEmpty {
					self.forceNextProgressUpdate()
					self.updateLiveActivityWithPausedState(activeDownloads: activeDownloads)
				}
			}

			return
		}

		// Non-resumable server/connection failures — cancel the download.
		if nsError.code == NSURLErrorCannotFindHost ||
		   nsError.code == NSURLErrorCannotConnectToHost ||
		   nsError.code == NSURLErrorBadURL ||
		   nsError.code == NSURLErrorUnsupportedURL ||
		   nsError.code == NSURLErrorResourceUnavailable ||
		   nsError.code == NSURLErrorFileDoesNotExist ||
		   nsError.code == NSURLErrorNoPermissionsToReadFile {
			if isAppInBackground {
				sendCompletionNotification(for: download, status: "❌ Download failed - cannot connect to server")
			} else {
				showUIErrorMessage(for: download, error: nsError)
			}

			download.isActive = false

			DispatchQueue.main.async {
				self.allActivityDownloads.removeValue(forKey: download.id)
				self.finishedDownloadingIDs.remove(download.id)

				if let index = self.getDownloadIndex(by: download.id) {
					self.downloads.remove(at: index)
				}

				let remainingActiveDownloads = self.downloads.filter {
					($0.progress > 0 && $0.progress < 1.0 && !$0.isPaused) ||
					($0.unpackageProgress > 0 && $0.unpackageProgress < 1.0)
				}

				if !remainingActiveDownloads.isEmpty && self.downloadActivity != nil {
					self.forceNextProgressUpdate()
					self.updateLiveActivity(activeDownloads: remainingActiveDownloads)
				} else {
					self.dismissLiveActivityImmediately()
				}
			}

			return
		}

		// Any other non-recoverable error — drop the download.
		if isAppInBackground {
			sendCompletionNotification(for: download, status: "❌ Download failed")
		} else {
			showUIErrorMessage(for: download, error: nsError)
		}

			download.isActive = false

			DispatchQueue.main.async {
				self.allActivityDownloads.removeValue(forKey: download.id)
				self.finishedDownloadingIDs.remove(download.id)

				if let index = self.getDownloadIndex(by: download.id) {
					self.downloads.remove(at: index)
				}

				let remainingActiveDownloads = self.downloads.filter {
					($0.progress > 0 && $0.progress < 1.0 && !$0.isPaused) ||
					($0.unpackageProgress > 0 && $0.unpackageProgress < 1.0)
				}

				if !remainingActiveDownloads.isEmpty && self.downloadActivity != nil {
					self.forceNextProgressUpdate()
					self.updateLiveActivity(activeDownloads: remainingActiveDownloads)
				} else {
					self.dismissLiveActivityImmediately()
				}
			}
	}
	
	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		DispatchQueue.main.async {
			self.backgroundCompletionHandler?()
			self.backgroundCompletionHandler = nil
		}
	}
}

// MARK: - UNUserNotificationCenterDelegate

extension DownloadManager: UNUserNotificationCenterDelegate {
	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
		completionHandler([.banner, .sound, .badge])
	}
	
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		// The release banner belongs to the self-updater, not to a download; a tap opens the
		// update sheet instead of doing nothing.
		let identifier = response.notification.request.identifier
		if SelfUpdateNotifier.isReleaseNotification(identifier) {
			Task { @MainActor in SelfUpdateNotifier.handleTap(identifier: identifier) }
		}
		completionHandler()
	}
}
