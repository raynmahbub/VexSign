//
//  WatchSessionStore.swift
//  VexSignWatch
//
//  The watch half of the companion. It receives the snapshot the iPhone pushes
//  over WatchConnectivity, mirrors it into the watch's app group so the
//  complication can read it without a session, and sends the four commands the
//  iPhone's `CompanionBridge` knows how to run.
//
//  Everything the watch shows is a mirror: signing, installing and storage stay
//  on the phone, which is the only device that can do them.
//

import Foundation
import SwiftUI
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchSessionStore: NSObject, ObservableObject, WCSessionDelegate {
	static let shared = WatchSessionStore()

	@Published private(set) var snapshot: CompanionSnapshot?
	@Published private(set) var isActivated = false
	@Published private(set) var isReachable = false
	@Published private(set) var lastCommand: String?

	private var _pendingCommand: CompanionCommand?

	private override init() {
		super.init()
	}

	// MARK: Lifecycle

	func activate() {
		guard WCSession.isSupported() else { return }
		let session = WCSession.default
		if session.delegate !== self {
			session.delegate = self
		}
		if session.activationState != .activated {
			session.activate()
		} else {
			isActivated = true
			isReachable = session.isReachable
		}

		// The phone may have published before this app ever launched.
		if snapshot == nil, !session.applicationContext.isEmpty {
			_ingest(session.applicationContext)
		} else if snapshot == nil {
			snapshot = WatchSnapshotStore.load()
		}
	}

	// MARK: Commands

	func send(_ command: CompanionCommand) {
		guard WCSession.isSupported() else { return }
		lastCommand = command.title

		let session = WCSession.default
		guard session.activationState == .activated else {
			_pendingCommand = command
			activate()
			return
		}

		_dispatchActivatedCommand(command, on: session)
	}

	private func _dispatchActivatedCommand(_ command: CompanionCommand, on session: WCSession) {
		let message: [String: Any] = [CompanionCommand.contextKey: command.rawValue]
		if session.isReachable {
			// Fall back to transferUserInfo if the live link drops mid-flight so the
			// command is queued rather than silently discarded.
			session.sendMessage(message, replyHandler: nil) { _ in
				WCSession.default.transferUserInfo(message)
			}
		} else {
			// Queued by the system and delivered the next time the phone is in
			// range, so a command pressed on a wrist in airplane mode is not lost.
			session.transferUserInfo(message)
		}
	}

	// MARK: Ingest

	private func _ingest(_ context: [String: Any]) {
		guard let received = CompanionSnapshot.snapshot(from: context) else { return }
		snapshot = received
		// The complication reads this; without it a watch face cannot update.
		WatchSnapshotStore.store(received)
		WidgetCenter.shared.reloadAllTimelines()
	}

	// MARK: WCSessionDelegate — called on a WatchConnectivity queue

	nonisolated func session(
		_ session: WCSession,
		activationDidCompleteWith activationState: WCSessionActivationState,
		error: Error?
	) {
		let reachable = session.isReachable
		let context = session.applicationContext
		Task { @MainActor in
			self.isActivated = activationState == .activated
			self.isReachable = reachable
			if activationState == .activated {
				if !context.isEmpty {
					self._ingest(context)
				}
				if let pending = self._pendingCommand {
					self._pendingCommand = nil
					self._dispatchActivatedCommand(pending, on: WCSession.default)
				}
			}
		}
	}

	nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
		Task { @MainActor in
			self._ingest(applicationContext)
		}
	}

	nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
		Task { @MainActor in
			self._ingest(message)
		}
	}

	nonisolated func session(
		_ session: WCSession,
		didReceiveMessage message: [String: Any],
		replyHandler: @escaping ([String: Any]) -> Void
	) {
		replyHandler([:])
		Task { @MainActor in
			self._ingest(message)
		}
	}

	nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
		Task { @MainActor in
			self._ingest(userInfo)
		}
	}

	nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
		let reachable = session.isReachable
		Task { @MainActor in
			self.isReachable = reachable
		}
	}
}
