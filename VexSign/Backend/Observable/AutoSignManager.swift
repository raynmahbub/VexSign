//
//  AutoSignManager.swift
//  VexSign
//
//  Created by VexSign Team on 24.08.2026.
//

import Foundation
import SwiftUI
import NimbleExtensions

@MainActor
final class AutoSignManager {
	static let shared = AutoSignManager()

	nonisolated static let enabledKey = "VexSign.autoSignAfterImport"

	private var _tail: Task<Void, Never> = Task {}

	private init() {}

	nonisolated static var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: enabledKey)
	}

	/// True when the saved options can produce a signed app without asking anything.
	nonisolated static var canSign: Bool {
		OptionsManager.shared.options.signingOption != .default || _certificate() != nil
	}

	/// One app at a time. Signing is memory heavy and `SigningLog` is a single shared console.
	func sign(_ app: AppInfoPresentable) async -> Result<Signed, Error> {
		let previous = _tail
        // Keep Core Data results on the main actor; Task.value carries only Void.
        var result: Result<Signed, Error>?
        let job = Task { @MainActor in
            await previous.value
            result = await Self._perform(app)
        }
        _tail = job
        await job.value
        return result ?? .failure(CancellationError())
	}

	private static func _perform(_ app: AppInfoPresentable) async -> Result<Signed, Error> {
		let stored = SigningProfileStore.shared.profile(forBundleID: app.identifier)
		let options = (stored?.options ?? Options.batchBase).resolved(for: app)
		let certificate = SigningProfileStore.shared.certificate(for: stored) ?? _certificate()

		guard options.signingOption != .default || certificate != nil else {
			return .failure(AutoSignError.noCertificate)
		}

		let result = await withCheckedContinuation { continuation in
			FR.signPackageFile(app, using: options, icon: nil, certificate: certificate) {
				continuation.resume(returning: $0)
			}
		}

		guard case .success(let signed) = result else { return result }

		// The unsigned copy only existed to feed the signer. Deleted before the cleanup runs so
		// nothing below reads an already deleted object.
		Storage.shared.deleteApp(for: app)

		// Auto cleanup: drops the signed copy when it isn't being installed and sweeps the
		// storage toggles (caches, temporary files, leftovers, exported IPAs).
		CleanupManager.shared.runAfterSign(
			source: nil,
			signed: signed,
			keepsSignedApp: options.post_installAppAfterSigned
		)

		if options.post_installAppAfterSigned {
			InstallQueue.shared.enqueue(signed)
		}

		return result
	}

	nonisolated private static func _certificate() -> CertificatePair? {
		Storage.shared.getCertificate(for: UserDefaults.standard.integer(forKey: "vexsign.selectedCert"))
	}
}

enum AutoSignError: LocalizedError {
	case noCertificate

	var errorDescription: String? {
		switch self {
		case .noCertificate: return .localized("Auto sign needs a certificate. Import one in Settings, or turn auto sign off.")
		}
	}
}
