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
        guard Thread.isMainThread else {
            try DispatchQueue.main.sync { try self.handlePackageFile(url: url, dl: dl) }
            return
        }
        guard !dl.isImporting, !dl.isVerifying,
              downloads.contains(where: { $0 === dl }),
              dl.importControl.isControllable,
              let token = dl.packageVerification.begin() else { return }
        // Claim ownership synchronously, before lifecycle retries can schedule another worker.
        dl.pendingFileURL = url
        checkpointRecovery(dl, stage: .verifying, file: url)
        dl.isVerifying = true
        dl.progress = 1.0
        let expectation = dl.integrity ?? DownloadIntegrity.Expectation()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let checkpoint = {
                try dl.packageVerification.check(token)
                try dl.importControl.checkpoint()
                try dl.packageVerification.check(token)
            }
            do {
                let verdict = try DownloadIntegrity.verify(fileAt: url, expectation: expectation, cancellationCheck: checkpoint)
                let auditHash: String?
                if expectation.sha256 == nil {
                    auditHash = try FileIntegrity.sha256(of: url, cancellationCheck: checkpoint)
                } else {
                    switch verdict {
                    case .verified: auditHash = expectation.sha256
                    case .mismatch(let failures):
                        auditHash = failures.compactMap { failure -> String? in
                            if case let .hash(_, actual) = failure { return actual }
                            return nil
                        }.first
                    case .unverified: auditHash = nil
                    }
                }
                try checkpoint()
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.downloads.contains(where: { $0 === dl }), dl.importControl.isControllable else {
                        self.finishCancelledVerification(url: url, dl: dl)
                        return
                    }
                    let requiresDecision: Bool
                    if case .mismatch = verdict { requiresDecision = true } else { requiresDecision = false }
                    guard dl.packageVerification.finish(token, requiresDecision: requiresDecision) else {
                        self.finishCancelledVerification(url: url, dl: dl)
                        return
                    }
                    dl.isVerifying = false
                    dl.verificationAuditHash = auditHash
                    switch verdict {
                    case .verified(let checks):
                        SigningLog.shared.info(.localized("%@ matches all %lld check(s) the source published.", arguments: dl.fileName, checks), category: "download")
                        self.beginPackageImport(url: url, dl: dl, verifiedHash: auditHash)
                    case .unverified:
                        self.beginPackageImport(url: url, dl: dl, verifiedHash: auditHash)
                    case .mismatch(let failures):
                        let message = DownloadIntegrity.describe(failures, fileName: dl.fileName)
                        SigningLog.shared.error(message, category: "download")
                        self.finishImport(of: dl, succeeded: false)
                        self.presentIntegrityFailure(for: dl, failures: failures, message: message, fileURL: url)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.finishCancelledVerification(url: url, dl: dl) }
            }
        }
    }

    /// Only delete our own staged download, after its verifier has released its file handle.
    func finishCancelledVerification(url: URL, dl: Download) {
        dl.packageVerification.cancel()
        dl.isVerifying = false
        dl.isPaused = false
        if url.deletingLastPathComponent().standardizedFileURL == FileManager.default.downloadStaging.standardizedFileURL {
            do { try FileManager.default.removeItem(at: url) }
            catch {
                SigningLog.shared.warn(.localized("Could not remove a cancelled verification file: %@", arguments: error.localizedDescription), category: "download")
            }
        }
        allActivityDownloads.removeValue(forKey: dl.id)
        finishedDownloadingIDs.remove(dl.id)
        finishImport(of: dl, succeeded: false)
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
		guard !isAppInBackground, let errorDelegate else {
            dl.packageVerification.cancel()
			// Nobody to ask: discard it, and say so.
			discardRejectedPackage(at: fileURL, fileName: dl.fileName)
			sendCompletionNotification(for: dl, status: "❌ " + .localized("Download failed a check"))
			return
		}

        checkpointRecovery(dl, stage: .awaitingDecision, file: fileURL)
		dl.retainedPackageURL = fileURL
        integrityDecisions[ObjectIdentifier(dl)] = dl

		errorDelegate.showUIErrorMessage(
			title: .localized("Download failed a check"),
			message: message,
			actionTitle: .localized("Import Anyway"),
			action: { [weak self, weak dl] in
				guard let self, let dl else { return }
				self.importAnyway(dl, failures: failures)
			},
			dismissTitle: .localized("Delete"),
			onDismiss: { [weak self, weak dl] in
				guard let self, let dl, self.integrityDecisions[ObjectIdentifier(dl)] === dl else { return }
				dl.retainedPackageURL = nil
                dl.packageVerification.cancel()
                self.integrityDecisions.removeValue(forKey: ObjectIdentifier(dl))
                self.clearRecovery(dl)
				self.discardRejectedPackage(at: fileURL, fileName: dl.fileName)
			}
		)
	}

	/// Imports a download the user has explicitly accepted despite a failed integrity check.
	///
	/// This is the only bypass, it is per-file, and the expectation is *not* cleared: downloading the
	/// same app again is checked again from scratch.
	func importAnyway(_ dl: Download, failures: [DownloadIntegrity.Failure]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.importAnyway(dl, failures: failures) }
            return
        }
		guard let url = dl.retainedPackageURL else {
			SigningLog.shared.error(
				.localized("Nothing left to import for %@ — the rejected file is gone.", arguments: dl.fileName),
				category: "download"
			)
			return
		}

        guard integrityDecisions[ObjectIdentifier(dl)] === dl, dl.importControl.isControllable,
              dl.packageVerification.acceptOverride() else { return }

		SigningLog.shared.warn(
			.localized("Importing %@ anyway, at the user's request, despite: %@", arguments: dl.fileName, DownloadIntegrity.describe(failures, fileName: dl.fileName)),
			category: "download"
		)
		dl.retainedPackageURL = nil

		// The row was removed when the check failed. Put it back: the import is about to happen, the
		// user should see it, and `finishImport` needs something to finish.
		if !downloads.contains(where: { $0 === dl }) {
			downloads.append(dl)
			objectWillChange.send()
		}

        integrityDecisions.removeValue(forKey: ObjectIdentifier(dl))
		beginPackageImport(url: url, dl: dl, verifiedHash: dl.verificationAuditHash)
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
    private func beginPackageImport(url: URL, dl: Download, verifiedHash: String? = nil) {
        guard downloads.contains(where: { $0 === dl }), dl.importControl.isControllable else {
            finishCancelledVerification(url: url, dl: dl)
            return
        }
        if let verifiedHash {
            SigningLog.shared.info(.localized("SHA-256 of %@: %@", arguments: dl.fileName, verifiedHash), category: "download")
        }
        // Handoff on the same main-queue turn, not in a later callback that cancellation could overtake.
        objectWillChange.send()
        dl.isVerifying = false
        dl.progress = 1.0
        dl.pendingFileURL = url
        checkpointRecovery(dl, stage: .importing, file: url)
        beginImport(for: dl)

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

	/// Main-actor isolated because everything it touches is: `SigningModeManager`,
	/// `SigningProfileStore`, `InstallQueue`, `AutoSignManager` and this manager's own
	/// `objectWillChange`/`finishImport`. Every caller already runs there — the two
	/// `DispatchQueue.main.async` branches in `DownloadManager.swift` and the
	/// `@MainActor` `ImportDuplicateReview.resolve` completion — so this annotates the
	/// isolation that was always true. Without it the compiler treats the body as
	/// nonisolated and the main-actor accesses become Swift 6 errors.
	@MainActor
	func autoSignOrFinish(_ app: AppInfoPresentable, for download: Download) {
		guard AutoSignManager.isEnabled else {
			if isAppInBackground { sendCompletionNotification(for: download, status: "✅ Added to Library") }
			finishImport(of: download, succeeded: true)
			return
		}

        do {
            if try SigningModeManager.shared.pipeline(for: app) == .containerized {
                let profile = SigningProfileStore.shared.profile(forBundleID: app.identifier)
                let options = (profile?.options ?? Options.batchBase).resolved(for: app)
                if options.post_installAppAfterSigned {
                    InstallQueue.shared.enqueue(app)
                    report(for: download, status: "✅ Guest import queued") {
                        Toast.info(.localized("Guest import queued. Confirm it in the embedded container."))
                    }
                } else {
                    report(for: download, status: "✅ Added to Library") {}
                }
                finishImport(of: download, succeeded: true)
                return
            }
        } catch {
            report(for: download, status: "❌ Install route unavailable") {
                Toast.error(error.localizedDescription, duration: .sticky)
            }
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

        clearRecovery(download)
		download.isActive = false
        download.isVerifying = false
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
			(other.isActive || other.isWaitingForSlot || other.isVerifying || other.isSigning || (other.progress > 0 && other.progress < 1.0) || (other.unpackageProgress > 0 && other.unpackageProgress < 1.0))
		}

		if let index = downloads.firstIndex(where: { $0 === download }) {
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
