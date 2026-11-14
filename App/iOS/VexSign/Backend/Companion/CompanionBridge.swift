//
//  CompanionBridge.swift
//  VexSign
//
//  The iPhone half of the Apple Watch companion. It pushes a `CompanionSnapshot`
//  to the watch over WatchConnectivity and runs the commands the watch sends
//  back — each one routed to the same manager the matching App Intent uses, so
//  there is a single implementation of "refresh", "check certificates",
//  "update all" and "clean now".
//
//  The watch is a mirror: it can trigger work on the phone, but signing,
//  installing and storage all stay here.
//

import Foundation
import SwiftUI
import WatchConnectivity
import OSLog

final class CompanionBridge: NSObject, ObservableObject, WCSessionDelegate {
	static let shared = CompanionBridge()

	/// Opt-in, because activating a WCSession on every launch is not free.
	static let enabledKey = "VexSign.companion.watchEnabled"

	@Published private(set) var isActivated = false
	@Published private(set) var isWatchPaired = false
	@Published private(set) var isWatchAppInstalled = false
	@Published private(set) var isReachable = false
	@Published private(set) var lastPush: Date?
	@Published private(set) var lastCommand: String?

	private override init() {
		super.init()
	}

	static var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: enabledKey)
	}

	// MARK: Lifecycle

	/// Called from the app delegate when the switch is on, and again whenever the
	/// user flips it.
	func activateIfNeeded() {
		guard WCSession.isSupported() else { return }
		guard Self.isEnabled else {
			WCSession.default.delegate = nil
			return
		}

		let session = WCSession.default
		if session.delegate !== self {
			session.delegate = self
		}
		session.activate()
	}

	func setEnabled(_ enabled: Bool) {
		UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
		enabled ? activateIfNeeded() : _deactivate()
		if enabled {
			pushSnapshot()
		}
	}

	private func _deactivate() {
		WCSession.default.delegate = nil
		Task { @MainActor in
			self.isActivated = false
			self.isReachable = false
		}
	}

	// MARK: Snapshot

	/// Same fields as the Web Manager's `/api/status` + `/api/library` +
	/// `/api/updates`, so the watch shows exactly what the other companions show.
	@MainActor
	static func currentSnapshot() -> CompanionSnapshot {
		let certificates = Storage.shared.getAllCertificates()
		let active = certificates.first(where: { $0.isDefault })
			?? certificates.first(where: { !$0.revoked })
			?? certificates.first

		let apps = Storage.shared.getAllApps()

		let status = CompanionStatus(
			certValid: !(active?.revoked ?? false) && (active?.expiration ?? .distantPast) > Date(),
			certName: active.flatMap { $0.nickname ?? Storage.shared.getProvisionFileDecoded(for: $0)?.Name },
			certExpiry: active?.expiration?.ISO8601Format(),
			certDaysRemaining: active?.expiration.map { Int(floor($0.timeIntervalSinceNow / 86_400)) },
			certRevoked: active?.revoked ?? false,
			certPPQLess: active?.isPPQLess,
			installedApps: apps.count,
			signedApps: apps.filter { $0.isSigned }.count,
			pendingUpdates: AppUpdateChecker.shared.updateCount,
			storageFree: FileManager.default.availableImportantCapacity(at: URL.documentsDirectory)
		)

		let library = apps.prefix(60).map { app in
			CompanionLibraryEntry(
				name: app.name ?? "App",
				bundleID: app.identifier ?? "",
				version: app.version ?? "",
				size: 0,
				signed: app.isSigned
			)
		}

		let updates = AppStoreUpdateTracker.shared.infos.compactMap { bundleID, info -> CompanionUpdateEntry? in
			guard let app = apps.first(where: { $0.identifier == bundleID }) else { return nil }
			return CompanionUpdateEntry(
				name: app.name ?? info.name,
				bundleID: bundleID,
				installedVersion: app.version,
				availableVersion: info.version
			)
		}

		return CompanionSnapshot(
			status: status,
			library: Array(library),
			updates: updates,
			generatedAt: Date()
		)
	}

	/// `updateApplicationContext` so the watch has data even when its app was
	/// never opened, plus a direct message when it is in the foreground.
	func pushSnapshot() {
		guard WCSession.isSupported(), Self.isEnabled else { return }

		let session = WCSession.default
		guard session.activationState == .activated, session.isPaired else { return }

		Task { @MainActor in
			let context = Self.currentSnapshot().contextRepresentation
			do {
				try session.updateApplicationContext(context)
				if session.isReachable {
					session.sendMessage(context, replyHandler: nil, errorHandler: nil)
				}
				self.lastPush = Date()
			} catch {
				Logger.misc.error("Watch snapshot push failed: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	// MARK: Commands

	@MainActor
	private func _run(_ command: CompanionCommand) async {
		lastCommand = command.title

		switch command {
		case .refreshSources:
			await SourcesViewModel.shared.fetchSources(Storage.shared.getSources(), refresh: true)
		case .checkCertificates:
			await BatchCertChecker.shared.checkAll(online: false)
		case .updateAll:
			_ = await BackgroundAutomation.run(fromBackground: true)
		case .cleanNow:
			CleanupManager.shared.cleanNow()
		}

		pushSnapshot()
	}

	// MARK: WCSessionDelegate — called on a WatchConnectivity queue, never main

	func session(
		_ session: WCSession,
		activationDidCompleteWith activationState: WCSessionActivationState,
		error: Error?
	) {
		Task { @MainActor in
			self.isActivated = activationState == .activated
			self.isWatchPaired = session.isPaired
			self.isWatchAppInstalled = session.isWatchAppInstalled
			self.isReachable = session.isReachable
			if activationState == .activated {
				self.pushSnapshot()
			}
		}
	}

	func sessionDidBecomeInactive(_ session: WCSession) {}

	func sessionDidDeactivate(_ session: WCSession) {
		// A second watch can pair after the first one is unpaired.
		session.activate()
	}

	func sessionReachabilityDidChange(_ session: WCSession) {
		let reachable = session.isReachable
		Task { @MainActor in
			self.isReachable = reachable
			if reachable {
				self.pushSnapshot()
			}
		}
	}

	func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
		_handle(message)
	}

	/// Commands the watch queued while the phone was out of range.
	func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
		_handle(userInfo)
	}

	private func _handle(_ message: [String: Any]) {
		guard
			let raw = message[CompanionCommand.contextKey] as? String,
			let command = CompanionCommand(rawValue: raw)
		else { return }

		Task { @MainActor in
			await self._run(command)
		}
	}
}
