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
		session.activate()

		// The phone may have published before this app ever launched.
		if snapshot == nil, !session.applicationContext.isEmpty {
			_ingest(session.applicationContext)
		} else if snapshot == nil {
			snapshot = WatchSnapshotStore.load()
		}
	}

	// MARK: Commands

	func send(_ command: CompanionCommand) {
		lastCommand = command.title

		let message: [String: Any] = [CompanionCommand.contextKey: command.rawValue]
		let session = WCSession.default

		guard session.activationState == .activated else { return }

		if session.isReachable {
			session.sendMessage(message, replyHandler: nil, errorHandler: nil)
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
		Task { @MainActor in
			self.isActivated = activationState == .activated
			self.isReachable = session.isReachable
			if activationState == .activated, !session.applicationContext.isEmpty {
				self._ingest(session.applicationContext)
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

	nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
		let reachable = session.isReachable
		Task { @MainActor in
			self.isReachable = reachable
		}
	}
}
