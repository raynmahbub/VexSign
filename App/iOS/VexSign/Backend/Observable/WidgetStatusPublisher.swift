//
//  WidgetStatusPublisher.swift
//  VexSign
//
//  Writes the widget payload into the app group and asks WidgetKit to reload.
//  Called after anything the widget shows changes — certificate import/refresh,
//  an install, a sign, a cleanup — plus on launch, so the Home Screen never
//  renders a stale certificate countdown.
//

import Foundation
import WidgetKit
import OSLog

@MainActor
enum WidgetStatusPublisher {
	/// Rebuilds the payload from live state, stores it and reloads every timeline.
	static func publish(includeRepository: Bool = true) {
		let payload = currentPayload()

		guard payload.store() else {
			Logger.misc.error("Widget payload could not be written: app group unavailable")
			return
		}

		// The repository widget keeps its own (heavier) snapshot: its icons have to
		// be fetched into the app group before the extension can show them.
		if includeRepository { WidgetRepoPublisher.publish() }

		WidgetCenter.shared.reloadAllTimelines()
	}

	/// Payload for the current library/certificate state.
	static func currentPayload() -> WidgetStatusPayload {
		let certificates = Storage.shared.getAllCertificates()
		let active = certificates.first(where: { $0.isDefault })
			?? certificates.first(where: { !$0.revoked })
			?? certificates.first

		let apps = Storage.shared.getAllApps()

		return WidgetStatusPayload(
			certDaysRemaining: active?.expiration.map { Int(floor($0.timeIntervalSinceNow / 86_400)) },
			certName: active.flatMap { cert in
				cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name
			},
			certRevoked: active?.revoked ?? false,
			pendingUpdates: AppUpdateChecker.shared.updateCount,
			installedCount: apps.count,
			signedCount: apps.filter { $0.isSigned }.count,
			availableBytes: FileManager.default.availableImportantCapacity(at: URL.documentsDirectory),
			lastUpdated: Date()
		)
	}
}
