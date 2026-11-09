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

	// MARK: Running

	/// Runs a prepared queue. Returns when every item finished, failed or was skipped.
	func run(tasks prepared: [UpdateTask]) async {
		guard !isRunning, !prepared.isEmpty else { return }

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
			guard !_cancelled else {
				_markRemainingSkipped(from: index)
				break
			}

			// Skip apps that already no longer report an update (state changed mid-run).
			guard tasks[index].state != .skipped else { continue }

			switch await _update(at: index) {
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

	private func _update(at index: Int) async -> Result<Void, Error> {
		let task = tasks[index]
		let url = task.url

		tasks[index].state = .downloading
		let ipaURL: URL
		do {
			ipaURL = try await _download(url)
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
		let result = await _sign(imported)
		if case .success = result {
			tasks[index].state = .finished
		}
		return result
	}

	private func _download(_ url: URL) async throws -> URL {
		var request = URLRequest(url: url)
		request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		VexSignAPI.applyAuthHeaders(to: &request)

		let (tempURL, response) = try await URLSession.shared.download(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard (200..<300).contains(status) else {
			try? FileManager.default.removeItem(at: tempURL)
			throw Self.error(String.localized("The update did not download (HTTP %lld).", arguments: status))
		}

		let dir = FileManager.default.uniqueTemporaryDirectory("UpdateAll")
		let name = url.lastPathComponent.isEmpty ? "update.ipa" : url.lastPathComponent
		let file = dir.appendingPathComponent(name)
		try? FileManager.default.removeItem(at: file)
		try FileManager.default.moveItem(at: tempURL, to: file)
		return file
	}

	private func _import(_ ipa: URL) async throws -> AppInfoPresentable {
		try await withCheckedThrowingContinuation { continuation in
			FR.handlePackageFile(ipa) { result in
				continuation.resume(with: result)
			}
		}
	}

	private func _sign(_ app: AppInfoPresentable) async -> Result<Void, Error> {
		let profile = SigningProfileStore.shared.profile(forBundleID: app.identifier)
		let options = (profile?.options ?? OptionsManager.shared.options).resolved(for: app)
		let certificate = SigningProfileStore.shared.certificate(for: profile)

		guard options.signingOption != .default || certificate != nil else {
			return .failure(Self.error(.localized("No certificate. Import one in Settings → Certificates, or set the default signing option.")))
		}

		let result: Result<Signed, Error> = await withCheckedContinuation { continuation in
			FR.signPackageFile(app, using: options, icon: nil, certificate: certificate) { result in
				continuation.resume(returning: result)
			}
		}

		switch result {
		case .success(let signed):
			// The unsigned copy only existed to feed the signer.
			Storage.shared.deleteApp(for: app)

			CleanupManager.shared.runAfterSign(
				source: nil,
				signed: signed,
				keepsSignedApp: true
			)

			InstallQueue.shared.enqueue(signed)
			return .success(())
		case .failure(let error):
			return .failure(error)
		}
	}

	private static func error(_ message: String) -> Error {
		NSError(domain: "UpdateAll", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
	}
}
