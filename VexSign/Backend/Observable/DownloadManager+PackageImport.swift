//
//  DownloadManager+PackageImport.swift
//  VexSign
//
//  Integrity verification and the package-import path.
//
//  Split out of DownloadManager.swift; behaviour is unchanged.
//

import Foundation
import UIKit
import NimbleExtensions

extension DownloadManager {
	func handlePackageFile(url: URL, dl: Download) throws {
		guard !dl.isImporting else { return }

		let expectation = dl.integrity ?? DownloadIntegrity.Expectation()
		guard !expectation.isEmpty else {
			// Nothing was declared for this file: import it, and say what it was, exactly as before.
			beginPackageImport(url: url, dl: dl)
			return
		}

		// when the source declared a size (or a hash), check the file before anything is
		// unpacked. A truncated IPA used to reach the importer and fail there, with a message that
		// said nothing about the download. Reading and hashing a large file off the main thread
		// keeps the row responsive; the import itself only starts once the verdict is in.
		DispatchQueue.global(qos: .utility).async { [weak self] in
			let verdict = DownloadIntegrity.verify(fileAt: url, expectation: expectation)

			DispatchQueue.main.async {
				guard let self else { return }

				switch verdict {
				case .verified(let checks):
					SigningLog.shared.info(
						.localized("%@ matches all %lld check(s) the source published.", arguments: dl.fileName, checks),
						category: "download"
					)
					self.beginPackageImport(url: url, dl: dl)

				case .unverified:
					self.beginPackageImport(url: url, dl: dl)

				case .mismatch(let failures):
					let message = DownloadIntegrity.describe(failures, fileName: dl.fileName)
					SigningLog.shared.error(message, category: "download")

					// A failed check is a failed import: the row goes away, as it does for any other
					// failure. The one deliberate override therefore has to be offered here, in the
					// alert that reports the mismatch — see `presentIntegrityFailure`.
					self.finishImport(of: dl, succeeded: false)
					self.presentIntegrityFailure(for: dl, failures: failures, message: message, fileURL: url)
				}
			}
		}
	}

	/// Asks the user what to do with a file that did not match its source.
	///
	/// Two outcomes, both final for this file: import it deliberately, or delete it. There is no
	/// "dismiss and see" — leaving a rejected package on disk is how a stray file gets imported
	/// later by something that is not this alert.
	private func presentIntegrityFailure(
		for dl: Download,
		failures: [DownloadIntegrity.Failure],
		message: String,
		fileURL: URL
	) {
		guard !isAppInBackground else {
			// Nobody to ask: discard it, and say so.
			discardRejectedPackage(at: fileURL, fileName: dl.fileName)
			sendCompletionNotification(for: dl, status: "❌ " + .localized("Download failed a check"))
			return
		}

		dl.retainedPackageURL = fileURL

		errorDelegate?.showUIErrorMessage(
			title: .localized("Download failed a check"),
			message: message,
			actionTitle: .localized("Import Anyway"),
			action: { [weak self, weak dl] in
				guard let self, let dl else { return }
				self.importAnyway(dl, failures: failures)
			},
			dismissTitle: .localized("Delete"),
			onDismiss: { [weak self, weak dl] in
				guard let self, let dl else { return }
				dl.retainedPackageURL = nil
				self.discardRejectedPackage(at: fileURL, fileName: dl.fileName)
			}
		)
	}

	/// Imports a download the user has explicitly accepted despite a failed integrity check.
	///
	/// This is the only bypass, it is per-file, and the expectation is *not* cleared: downloading the
	/// same app again is checked again from scratch.
	func importAnyway(_ dl: Download, failures: [DownloadIntegrity.Failure]) {
		guard let url = dl.retainedPackageURL ?? dl.pendingFileURL else {
			SigningLog.shared.error(
				.localized("Nothing left to import for %@ — the rejected file is gone.", arguments: dl.fileName),
				category: "download"
			)
			return
		}

		SigningLog.shared.warn(
			.localized("Importing %@ anyway, at the user's request, despite: %@", arguments: dl.fileName, DownloadIntegrity.describe(failures, fileName: dl.fileName)),
			category: "download"
		)
		dl.retainedPackageURL = nil

		// The row was removed when the check failed. Put it back: the import is about to happen, the
		// user should see it, and `finishImport` needs something to finish.
		if !downloads.contains(where: { $0.id == dl.id }) {
			downloads.append(dl)
			objectWillChange.send()
		}

		beginPackageImport(url: url, dl: dl)
	}

	/// Deletes a file that failed its check. Unconditional, unlike `CleanupManager`: a file the user
	/// just refused must not survive because a cleanup preference is off.
	private func discardRejectedPackage(at url: URL, fileName: String) {
		do {
			try FileManager.default.removeItem(at: url)
			SigningLog.shared.info(
				.localized("Discarded %@ — it did not match what the source published.", arguments: fileName),
				category: "download"
			)
		} catch {
			SigningLog.shared.error(
				.localized("Could not delete the rejected download %@: %@", arguments: fileName, error.localizedDescription),
				category: "download"
			)
		}
	}

	/// The import path itself: hash for the Logs tab, then hand the file to the importer.
	private func beginPackageImport(url: URL, dl: Download) {
		// Integrity audit: record the SHA-256 of every downloaded package in the Logs
		// tab, so it can be compared later against a hash the source published.
		let label = dl.fileName
		DispatchQueue.global(qos: .utility).async {
			if let hash = FileIntegrity.sha256(of: url) {
				SigningLog.shared.info(.localized("SHA-256 of %@: %@", arguments: label, hash), category: "download")
			}
		}

		DispatchQueue.main.async {
			self.objectWillChange.send()
			dl.progress = 1.0
			// Retry point if the import dies before it finishes.
			dl.pendingFileURL = url
			self.beginImport(for: dl)
		}

		FR.handlePackageFile(url, download: dl) { result in
			switch result {
            case .failure(let error):
                if error is CancellationError {
                    self.allActivityDownloads.removeValue(forKey: dl.id)
                    self.finishedDownloadingIDs.remove(dl.id)
                    self.finishImport(of: dl, succeeded: false)
                    return
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)

				if self.isAppInBackground {
					self.sendCompletionNotification(for: dl, status: "❌ Import failed: \(error.localizedDescription)")
				} else {
					self.errorDelegate?.showUIErrorMessage(
						title: "Import Failed",
						message: error.localizedDescription
					)
				}

				DispatchQueue.main.async { self.finishImport(of: dl, succeeded: false) }
			case .success(let app):
				DispatchQueue.main.async {
					self.objectWillChange.send()
					dl.unpackageProgress = 1.0
					self.autoSignOrFinish(app, for: dl)
				}
			}
		}
	}

	func autoSignOrFinish(_ app: AppInfoPresentable, for download: Download) {
		guard AutoSignManager.isEnabled else {
			if isAppInBackground { sendCompletionNotification(for: download, status: "✅ Added to Library") }
			finishImport(of: download, succeeded: true)
			return
		}

		endImport(for: download)
		objectWillChange.send()
		download.isSigning = true

		Task { @MainActor in
			switch await AutoSignManager.shared.sign(app) {
			case .success:
				self.report(for: download, status: "✅ Signed") {
					Toast.success(.localized("Signed successfully"), systemImage: "checkmark.seal.fill")
				}
			case .failure(let error):
				// Keep the import so it can still be signed by hand.
				self.report(for: download, status: "❌ Signing failed") {
					Toast.error(error.localizedDescription, duration: .sticky)
				}
			}

			self.objectWillChange.send()
			download.isSigning = false
			self.finishImport(of: download, succeeded: true)
		}
	}

	private func report(for download: Download, status: String, toast: () -> Void) {
		if isAppInBackground {
			sendCompletionNotification(for: download, status: status)
		} else {
			toast()
		}
	}

	func finishImport(of download: Download, succeeded: Bool) {
		// Captured before `endImport()` clears it — the staged IPA is deleted below.
		let stagedURL = download.pendingFileURL

		download.isActive = false
		endImport(for: download)

		if succeeded {
			// Auto cleanup → "Delete Downloaded IPA": the archive already became a library app.
			Task { @MainActor in
				CleanupManager.shared.purgeDownloadArtifacts(fileURL: stagedURL, stageURL: nil)
			}
		}

		// Drop from activity tracking only once archiving completes (not on download finish).
		if succeeded {
			completedDownloadNames.append(download.fileName)
			allActivityDownloads.removeValue(forKey: download.id)
			finishedDownloadingIDs.remove(download.id)
		}

		// Snapshot before removing this one.
		let isLastDownload = !downloads.contains { other in
			other.id != download.id &&
			(other.isActive || other.isSigning || (other.progress > 0 && other.progress < 1.0) || (other.unpackageProgress > 0 && other.unpackageProgress < 1.0))
		}

		if let index = getDownloadIndex(by: download.id) {
			downloads.remove(at: index)
		}

		guard isLastDownload else { return }

		// Background archiving needs no completion state; foreground keeps it until reopened.
		if isAppInBackground {
			dismissLiveActivityImmediately()
		} else {
			endLiveActivity()
		}
	}
}
