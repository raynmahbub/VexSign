//
//  BatchJobRunner.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation
import SwiftUI
import NimbleExtensions

// MARK: - Model
struct BatchItem: Identifiable {
	enum State: Equatable {
		case queued
		case working
		case signed
		case alreadySigned
		case installed
		case failed(String)
		case skipped
	}

	let id: String
	let app: AppInfoPresentable
	var state: State = .queued
	var signed: Signed?

	init(app: AppInfoPresentable) {
		self.id = app.uuid ?? UUID().uuidString
		self.app = app
	}

	var installable: AppInfoPresentable { signed ?? app }
}

// MARK: - Runner
@MainActor
final class BatchJobRunner: ObservableObject {
	enum Mode {
		case sign
		case install
		case signAndInstall

		var signs: Bool { self != .install }
		var installs: Bool { self != .sign }
	}

	enum Phase: Equatable {
		case signing
		case installing
		case finished
	}

	@Published private(set) var items: [BatchItem]
	@Published private(set) var phase: Phase
	@Published private(set) var currentIndex: Int = 0
	@Published private(set) var currentInstaller: AppInstaller?
	/// Signing cannot be interrupted mid-app, so cancelling has to release the screen right away.
	@Published private(set) var isCancelled = false

	let mode: Mode
	private let _options: Options
	private let _overrides: [String: Options]
	private let _icons: [String: UIImage]
	private let _certificate: CertificatePair?
	private let _resignsSigned: Bool
	private var _cancelled = false
	private var _skipRequested = false
	private var _started = false
	private var _installContinuation: CheckedContinuation<Result<Void, Error>, Never>?

	init(
		apps: [AppInfoPresentable],
		mode: Mode,
		options: Options,
		overrides: [String: Options] = [:],
		icons: [String: UIImage] = [:],
		certificate: CertificatePair?,
		resignsSigned: Bool = true
	) {
		self.items = apps.map(BatchItem.init)
		self.mode = mode
		self._options = options
		self._overrides = overrides
		self._icons = icons
		self._certificate = certificate
		self._resignsSigned = resignsSigned
		self.phase = mode.signs ? .signing : .installing
	}

	var isFinished: Bool { phase == .finished }

	var succeeded: Int {
		items.filter { item in
			switch item.state {
			case .installed: true
			case .signed, .alreadySigned: !mode.installs
			default: false
			}
		}.count
	}

	var failed: Int {
		items.filter {
			if case .failed = $0.state { return true }
			return false
		}.count
	}

	func run() async {
		guard !_started else { return }
		_started = true

		// One assertion for the whole queue per-app ones drop to zero between apps and let iOS suspend us
		let keepAlive = BackgroundTaskManager(
			taskName: "Batch",
			expirationTitle: .localized("Batch continuing"),
			expirationBody: .localized("The remaining apps will continue when you reopen the app")
		)
		keepAlive.start()
		defer { keepAlive.stop() }

		if mode.signs {
			await _signAll()
		}

		if mode.installs, !_cancelled {
			await _installAll()
		}

		phase = .finished
	}

	func cancel() {
		_cancelled = true

		// Stop the item that is already running too, not just the next one: the run is owned by
		// `SigningService`, so this returns control to the queue once the in-flight item has
		// cleaned up and reported `.cancelled`.
		SigningService.shared.cancelAll()
		isCancelled = true
		currentInstaller?.stop()
		_resumeInstall(.success(()))
		SigningLiveActivityManager.shared.cancel()

		for index in items.indices where items[index].state == .queued || items[index].state == .working {
			items[index].state = .skipped
		}
	}

	/// A declined iOS install prompt leaves the status pending forever, with nothing else to wake it.
	func skipCurrentInstall() {
		_skipRequested = true
		_resumeInstall(.success(()))
	}

	// MARK: Phases

	private func _signAll() async {
		phase = .signing

		for index in items.indices {
			guard !_cancelled else { return }

			currentIndex = index

			let app = items[index].app

			guard _resignsSigned || !app.isSigned else {
				items[index].state = .alreadySigned
				continue
			}

			items[index].state = .working

			let options = _overrides[items[index].id] ?? _options.resolved(for: app)
			let icon = _icons[items[index].id]

			SigningLog.shared.info(
				.localized("Batch: signing %@ (%lld/%lld)", arguments: app.name ?? "", index + 1, items.count),
				category: "batch"
			)
			SigningLiveActivityManager.shared.start(
				appName: app.name ?? "App",
				currentApp: index + 1,
				totalApps: items.count
			)

			let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Signed, Error>, Never>) in
				FR.signPackageFile(app, using: options, icon: icon, certificate: _certificate) { result in
					continuation.resume(returning: result)
				}
			}

			switch result {
			case .success(let signed):
				items[index].signed = signed
				items[index].state = .signed
				SigningLog.shared.success(
					.localized("Batch: signed %@", arguments: app.name ?? ""),
					category: "batch"
				)

				// Per-app option first, then the global Auto Cleanup toggle.
				if !app.isSigned, options.post_deleteAppAfterSigned || CleanupManager.shared.deletesSourceAfterSign {
					Storage.shared.deleteApp(for: app)
				}
			case .failure(let error) where error is CancellationError:
				// Stopping mid-item is not a failure of that item: it was never signed, and the
				// pipeline removed its work directory on the way out.
				items[index].state = .skipped
				SigningLog.shared.info(
					.localized("Batch: cancelled %@", arguments: app.name ?? ""),
					category: "batch"
				)
			case .failure(let error):
				items[index].state = .failed(error.localizedDescription)
				SigningLog.shared.error(
					.localized("Batch: failed %@: %@", arguments: app.name ?? "", error.localizedDescription),
					category: "batch"
				)
			}
		}

		// After a cancel the activity was already ended by `cancel()`; completing it again would
		// put a finished batch back on the Lock Screen.
		if !_cancelled {
			SigningLiveActivityManager.shared.complete()
		}

		// One shared sweep for the whole batch: the apps were handled above, so this only
		// clears whichever storage toggles are on.
		CleanupManager.shared.runAfterSign(source: nil, signed: nil, keepsSignedApp: mode.installs)
	}

	private func _installAll() async {
		// Guest imports need an interactive, one-at-a-time handoff. A staged guest
		// must never flow through this batch's device-installed success/cleanup path.
		if UserDefaults.standard.integer(forKey: "VexSign.installationMethod") == 2 {
			for index in items.indices {
				switch items[index].state {
				case .signed, .alreadySigned, .queued:
					items[index].state = .failed(.localized("Guest import requires confirmation. Use the Library Install action for one app at a time, or select OTA/IDevice for device-install batches."))
				default: break
				}
			}
			return
		}
		phase = .installing

		for index in items.indices {
			guard !_cancelled else { return }
			// Still queued means install-only; anything else never produced a package.
			switch items[index].state {
			case .signed, .alreadySigned, .queued: break
			default: continue
			}

			currentIndex = index
			items[index].state = .working

			let installer = AppInstaller(app: items[index].installable)
			currentInstaller = installer

			let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
				_installContinuation = continuation
				installer.start { [weak self] outcome in
					if case .success(.cancelled) = outcome { self?._skipRequested = true }
					self?._resumeInstall(outcome.flatMap { value in
						guard value.countsAsInstall else {
							return .failure(NSError(domain: "Install", code: -1, userInfo: [NSLocalizedDescriptionKey:
								String.localized("No device installation was confirmed. Finish guest imports in the container.")]))
						}
						return .success(())
					})
				}
			}

			installer.stop()
			currentInstaller = nil

			guard !_cancelled else { return }

			if _skipRequested {
				_skipRequested = false
				items[index].state = .skipped
				continue
			}

			switch result {
			case .success:
				items[index].state = .installed
				InstallCleanup.stage(items[index].installable)
			case .failure(let error):
				items[index].state = .failed(error.localizedDescription)
			}
		}
	}

	private func _resumeInstall(_ result: Result<Void, Error>) {
		guard let continuation = _installContinuation else { return }
		_installContinuation = nil
		continuation.resume(returning: result)
	}
}
