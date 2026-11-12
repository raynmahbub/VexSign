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
	///
	/// `overridingBlockingIssues` is the user's explicit "Sign Anyway" on a review that listed
	/// blocking preflight issues. Library details shows that review and then called this without
	/// saying so, which left the engine in its strict mode: the run the user had just confirmed
	/// stopped on the very issue they accepted. Every caller that shows no review leaves it false.
	func sign(_ app: AppInfoPresentable, overridingBlockingIssues: Bool = false) async -> Result<Signed, Error> {
		let previous = _tail
        // Keep Core Data results on the main actor; Task.value carries only Void.
        var result: Result<Signed, Error>?
        let job = Task { @MainActor in
            await previous.value
            result = await Self._perform(app, overridingBlockingIssues: overridingBlockingIssues)
        }
        _tail = job
        await job.value
        return result ?? .failure(CancellationError())
	}

	private static func _perform(_ app: AppInfoPresentable, overridingBlockingIssues: Bool) async -> Result<Signed, Error> {
		let stored = SigningProfileStore.shared.profile(forBundleID: app.identifier)
		let options = (stored?.options ?? Options.batchBase).resolved(for: app)
		let certificate = SigningProfileStore.shared.certificate(for: stored) ?? _certificate()

		guard options.signingOption != .default || certificate != nil else {
			return .failure(AutoSignError.noCertificate)
		}

		// Saved settings never carry the files that were staged for one sign. Say so in the
		// run's own log instead of dropping them silently.
		var notices = OneShotTweakFiles.replayNotices(for: stored?.oneShotFileNames ?? [])

		// This path shows no sheet, so an identity substitution has to be said in the run's own
		// log: the app was signed with another key, and an update signed with a different one may
		// not install over the copy that is already there.
		if case .orphaned = SigningProfileStore.resolveIdentity(
			captured: stored?.certificateUUID,
			available: Set(Storage.shared.getAllCertificates().compactMap { $0.uuid?.lowercased() })
		) {
			notices.append(.localized("This app was signed with an identity that is no longer installed. It is being signed with the current selection, which may not install over the existing copy."))
		}

		let result = await withCheckedContinuation { continuation in
			FR.signPackageFile(
				app,
				using: options,
				icon: nil,
				certificate: certificate,
				overridesBlockingPreflightIssues: overridingBlockingIssues,
				notices: notices
			) {
				continuation.resume(returning: $0)
			}
		}

		guard case .success(let signed) = result else { return result }

		// The run succeeded, so `signed` stays in the library whatever the settings are. This
		// used to delete `app` and then let Auto Cleanup delete `signed` whenever the saved
		// settings did not install it: a successful re-sign with "Delete Signed App" on left no
		// copy at all.
		//
		// Only `app` can go now, and only once `signed` is confirmed to be in the library. An
		// import only existed to feed the signer and is removed as before. A signed copy stays
		// unless "Delete Signed App" asks for it to be removed. The storage toggles (caches,
		// temporary files, leftovers, exported IPAs) are swept in the same call.
		CleanupManager.shared.finishSign(source: app, output: signed, origin: .savedSettings)

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
