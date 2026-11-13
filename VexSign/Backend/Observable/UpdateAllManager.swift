//
//  UpdateAllManager.swift
//  VexSign
//
//  "Update All": one tap that takes every app with a pending update, downloads it,
//  re-signs it with the settings it was originally signed with (or the current
//  defaults), and queues the installs in order. The install itself still goes
//  through InstallQueue, so the user stays in the loop exactly like the App Store
//  does with its update prompt.
//

import Foundation
import SwiftUI
import AltSourceKit
import CoreData
import NimbleExtensions

// MARK: - Item
struct UpdateTask: Identifiable, Equatable {
	enum State: Equatable {
		case queued
		case downloading
		case importing
		case signing
		case finished
		case failed(String)
		case skipped
	}

	let id: String
	let app: ASRepository.App
	let sourceName: String
	let url: URL
	var installedAppUUID: String? = nil
	var sourceID: String? = nil
	var state: State = .queued

	static func == (lhs: UpdateTask, rhs: UpdateTask) -> Bool {
		lhs.id == rhs.id && lhs.state == rhs.state
	}
}

// MARK: - Manager
@MainActor
final class UpdateAllManager: ObservableObject {
	static let shared = UpdateAllManager()

	@Published private(set) var tasks: [UpdateTask] = []
	@Published private(set) var isRunning = false
	@Published private(set) var succeeded = 0
	@Published private(set) var failed = 0

	private var _cancelled = false

	private init() {}

	// MARK: Building the queue

	/// Builds the task list from the distributed `[ASRepository]` the App Store holds. Apps that
	/// are ignored, already matching, or lack a download URL are dropped.
	static func makeTasks(
		from repositories: [ASRepository],
		signedApps: FetchedResults<Signed>,
		importedApps: FetchedResults<Imported>
	) -> [(app: ASRepository.App, sourceName: String, hasUpdate: Bool)] {
		let ignored = SkippedUpdatesManager.persisted
		_ = signedApps; _ = importedApps

        // A background pass must not choose arbitrarily between repositories for one app.
        let grouped = Dictionary(grouping: AppUpdateChecker.shared.availableUpdates, by: { $0.installedAppUUID ?? "" })
        let unambiguous = Set(grouped.filter { !$0.key.isEmpty && $0.value.count == 1 }.values.flatMap { $0 }.map(\.id))
		var seen = Set<String>()
		var updates: [(app: ASRepository.App, sourceName: String, hasUpdate: Bool)] = []

		for source in repositories {
			for app in source.apps {
				guard !ignored.contains(app.id ?? "") else { continue }
				guard app.currentDownloadUrl != nil else { continue }
				guard seen.insert(app.currentUniqueId).inserted else { continue }
				let hasUpdate = unambiguous.contains(app.currentUniqueId)
				updates.append((app, source.name ?? "", hasUpdate))
			}
		}

		return updates
	}

	func makeTasks(from updates: [(app: ASRepository.App, sourceName: String, hasUpdate: Bool)]) -> [UpdateTask] {
		updates.compactMap { entry in
			guard let url = entry.app.currentDownloadUrl else { return nil }
			return UpdateTask(
				id: entry.app.currentUniqueId,
				app: entry.app,
				sourceName: entry.sourceName,
				url: url
			)
		}
	}

	/// Builds tasks for the scheduled auto-update pipeline. Manual Update All
	/// deliberately uses its separate overload and is not filtered by these preferences.
	func makeTasks(from updates: [AppUpdateChecker.SourcedUpdate], automaticOnly: Bool) -> [UpdateTask] {
		let preferences = UpdateMatchingPreferences.shared
		guard !automaticOnly || preferences.isAutoUpdateEnabled else { return [] }

		var seenInstalledApps = Set<String>()
		return updates.compactMap { update in
			guard let url = update.downloadURL else { return nil }
			if automaticOnly {
				guard let installedUUID = update.installedAppUUID,
					  preferences.isAutoUpdateAllowed(for: installedUUID),
					  let sourceID = update.sourceURL?.absoluteString ?? update.sourceID,
					  SourcePreferences.autoUpdatesEnabled(for: sourceID),
					  seenInstalledApps.insert(installedUUID).inserted else { return nil }
			}
			return UpdateTask(
				id: update.id,
				app: update.app,
				sourceName: update.sourceName,
				url: url,
				installedAppUUID: update.installedAppUUID,
				sourceID: update.sourceID
			)
		}
	}

	// MARK: Running

	/// Runs a prepared queue. Returns when every item finished, failed or was skipped.
	///
	/// `unattended` marks a run nobody is present for. Each item is then signed only if the
	/// background-signing permission covers the certificate that item resolves to, checked
	/// when the item is signed, so a per-app pinned certificate cannot widen the permission
	/// and turning it off stops the rest of the queue.
	func run(tasks prepared: [UpdateTask], automatic: Bool = false, unattended: Bool = false) async {
		guard !isRunning, !prepared.isEmpty else { return }
		_unattended = unattended

		// Game Mode: updating apps means downloading them. Say so rather than silently
		// doing nothing, since this is a deliberate tap.
		guard !GameMode.isEnabled else {
			GameMode.reportBlockedInline(.localized("Updating apps"))
			return
		}

		isRunning = true
		_cancelled = false
		succeeded = 0
		failed = 0
		tasks = prepared

		let keepAlive = BackgroundTaskManager(
			taskName: "UpdateAll",
			expirationTitle: .localized("Updates continuing"),
			expirationBody: .localized("The remaining updates will continue when you reopen the app")
		)
		keepAlive.start()
		defer { keepAlive.stop() }

		for index in tasks.indices {
			guard !_cancelled, !Task.isCancelled else {
				_markRemainingSkipped(from: index)
				break
			}

			// Skip apps that already no longer report an update (state changed mid-run).
			guard tasks[index].state != .skipped else { continue }

			switch await _update(at: index, automatic: automatic) {
			case .success:
				succeeded += 1
			case .failure(let error):
				failed += 1
				tasks[index].state = .failed(error.localizedDescription)
			}
		}

		isRunning = false
	}

	func cancel() {
		_cancelled = true
	}

	private func _markRemainingSkipped(from index: Int) {
		guard index < tasks.count else { return }
		for i in index..<tasks.count where tasks[i].state != .finished {
			tasks[i].state = .skipped
		}
	}

	// MARK: One app

	private func _update(at index: Int, automatic: Bool) async -> Result<Void, Error> {
		let task = tasks[index]
		let url = task.url

		tasks[index].state = .downloading
		let ipaURL: URL
		do {
			ipaURL = try await _download(
				url,
				automatic: automatic,
				expectation: task.app.downloadIntegrityExpectation
			)
		} catch {
			return .failure(error)
		}

		tasks[index].state = .importing
		let imported: AppInfoPresentable
		do {
			imported = try await _import(ipaURL)
		} catch {
			try? FileManager.default.removeItem(at: ipaURL)
			return .failure(error)
		}
		try? FileManager.default.removeItem(at: ipaURL)

		tasks[index].state = .signing
        do {
            if try SigningModeManager.shared.pipeline(for: imported) == .containerized {
                // The container signs during its confirmed import. Do not manufacture a paid
                // signing requirement (or a second signed library copy) for a guest update.
                if !automatic || UpdateMatchingPreferences.shared.autoInstallAfterUpdate {
                    InstallQueue.shared.enqueue(imported)
                }
                tasks[index].state = .finished
                return .success(())
            }
        } catch {
            tasks[index].state = .failed(error.localizedDescription)
            return .failure(error)
        }

		let result = await _sign(imported, automatic: automatic)
		if case .success = result {
			tasks[index].state = .finished
		}
		return result
	}

	private func _download(
		_ url: URL,
		automatic: Bool,
		expectation: DownloadIntegrity.Expectation
	) async throws -> URL {
		try PackageDownloadURLPolicy.validateInitialURL(url)
		guard !DownloadIntegrity.expectationExceedsPackageLimit(expectation) else {
			throw PackageDownloadURLPolicy.Failure.packageTooLarge
		}
		var request = URLRequest(url: url)
		request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		VexSignAPI.applyAuthHeaders(to: &request)

		let wifiOnly = DownloadPreferences.wifiOnly
			|| (automatic && UpdateMatchingPreferences.shared.autoUpdateWifiOnly)
		if wifiOnly && DownloadPreferences.isOnExpensivePath {
			throw Self.error(.localized("This update is waiting for Wi-Fi."))
		}
		let configuration = URLSessionConfiguration.ephemeral
		configuration.allowsExpensiveNetworkAccess = !wifiOnly
		configuration.allowsConstrainedNetworkAccess = !wifiOnly
		let redirectDelegate = PackageDownloadRedirectDelegate(maximumBytes: DownloadIntegrity.maximumPackageBytes)
		let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }
		let tempURL: URL
		let response: URLResponse
		do {
			(tempURL, response) = try await session.download(for: request, delegate: redirectDelegate)
		} catch {
			if redirectDelegate.didExceedLimit { throw PackageDownloadURLPolicy.Failure.packageTooLarge }
			throw error
		}
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard (200..<300).contains(status) else {
			try? FileManager.default.removeItem(at: tempURL)
			throw Self.error(String.localized("The update did not download (HTTP %lld).", arguments: status))
		}

		let dir = try DownloadStagingPath.createTemporaryDirectory(label: "UpdateAll")
		let name = DownloadStagingPath.safeFilename(url.lastPathComponent.isEmpty ? "update.ipa" : url.lastPathComponent)
		let file = DownloadStagingPath.destination(in: dir, suggestedFilename: name)
		try FileManager.default.moveItem(at: tempURL, to: file)

		// Update All imports directly instead of passing through DownloadManager's
		// integrity gate. Check the repository's declared size/hash here before the
		// importer sees the package; large hashes run away from the main actor.
		let integrityFailure = await Task.detached(priority: .utility) {
			DownloadIntegrity.automaticImportFailure(
				fileAt: file,
				expectation: expectation,
				fileName: name
			)
		}.value
		if let integrityFailure {
			try? FileManager.default.removeItem(at: file) // try? ok: best-effort cleanup must not hide the integrity failure
			throw Self.error(integrityFailure)
		}
		return file
	}

	private func _import(_ ipa: URL) async throws -> AppInfoPresentable {
		try await withCheckedThrowingContinuation { continuation in
			FR.handlePackageFile(ipa) { result in
				continuation.resume(with: result)
			}
		}
	}

	/// Set for the duration of one `run`; read on the main actor only.
	private var _unattended = false

	private func _sign(_ app: AppInfoPresentable, automatic: Bool) async -> Result<Void, Error> {
		let profile = SigningProfileStore.shared.profile(forBundleID: app.identifier)
		let rule = PerAppUpdateRulesStore.persisted[app.identifier ?? ""] ?? PerAppUpdateRule()
		let baseOptions = rule.preserveSigningOptions
			? (profile?.options ?? OptionsManager.shared.options)
			: OptionsManager.shared.options
		let options = baseOptions.resolved(for: app)
		let certificate = _certificate(profile: profile, rule: rule, automatic: automatic)

		guard options.signingOption != .default || certificate != nil else {
			return .failure(Self.error(.localized("No certificate. Import one in Settings → Certificates, or set the default signing option.")))
		}

		if _unattended {
			let decision = UnattendedSigningGrantStore.decision(
				scope: .signAndQueueUpdates, certificateUUID: certificate?.uuid
			)
			guard decision.isAuthorized else {
				return .failure(Self.error(decision.explanation))
			}
		}

		// An updated copy is a new bundle: a tweak file that was added for one earlier sign is
		// not in it and is not kept anywhere to add again. The saved settings no longer point at
		// such files, so the run says which ones it left out instead of leaving them out silently.
		let notices = rule.preserveSigningOptions
			? OneShotTweakFiles.replayNotices(for: profile?.oneShotFileNames ?? [])
			: []

		let result: Result<Signed, Error> = await withCheckedContinuation { continuation in
			FR.signPackageFile(app, using: options, icon: nil, certificate: certificate, notices: notices) { result in
				continuation.resume(returning: result)
			}
		}

		switch result {
		case .success(let signed):
			// The copy that was imported for this update only existed to feed the signer. It is
			// removed once the signed copy is confirmed to be in the library; the signed copy
			// stays whatever the settings are.
			CleanupManager.shared.finishSign(source: app, output: signed, origin: .update)

			if !automatic || UpdateMatchingPreferences.shared.autoInstallAfterUpdate {
				InstallQueue.shared.enqueue(signed)
			}
			return .success(())
		case .failure(let error):
			return .failure(error)
		}
	}

	private func _certificate(
		profile: SigningProfile?,
		rule: PerAppUpdateRule,
		automatic: Bool
	) -> CertificatePair? {
		let certificates = Storage.shared.getAllCertificates()
		if let pinnedUUID = rule.pinnedCertificateUUID,
		   let pinned = certificates.first(where: { $0.uuid == pinnedUUID }) {
			return pinned
		}

		if automatic {
			let requestedName = UpdateMatchingPreferences.shared.autoUpdateCertificate
			if requestedName != "Global Default",
			   let selected = certificates.first(where: { certificate in
				   certificate.uuid == requestedName
					   || certificate.nickname == requestedName
					   || Storage.shared.getProvisionFileDecoded(for: certificate)?.Name == requestedName
			   }) {
				return selected
			}
		}
		return SigningProfileStore.shared.certificate(for: profile)
	}

	private static func error(_ message: String) -> Error {
		NSError(domain: "UpdateAll", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
	}
}
