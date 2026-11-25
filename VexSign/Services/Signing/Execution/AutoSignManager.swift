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

	/// Injected by the composition root. Every sign caller — import, web upload, Shortcut,
	/// library, batch and update — goes through `sign`, so one recorder covers them all.
	var outcomeRecorder: OperationOutcomeRecording?

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
	func sign(
		_ app: AppInfoPresentable,
		overridingBlockingIssues: Bool = false,
		repeatInstall: Bool = false,
		recordOutcome: Bool = true
	) async -> Result<Signed, Error> {
		let previous = _tail
		let correlationID = UUID().uuidString.lowercased()
		let startedAt = Date()
        // Keep Core Data results on the main actor; Task.value carries only Void.
        var result: Result<Signed, Error>?
        let job = Task { @MainActor in
            await previous.value
            result = await Self._perform(app, overridingBlockingIssues: overridingBlockingIssues, repeatInstall: repeatInstall)
			if recordOutcome, let outcomeRecorder {
				await outcomeRecorder(Self.outcome(
					correlationID: correlationID,
					result: result,
					startedAt: startedAt
				))
			}
        }
        _tail = job
        await job.value
        return result ?? .failure(CancellationError())
	}

	private static func outcome(
		correlationID: String,
		result: Result<Signed, Error>?,
		startedAt: Date
	) -> OperationOutcomeRecord {
		let status: OperationOutcomeStatus
		let reason: String?
		switch result {
		case .some(.success):
			status = .succeeded
			reason = nil
		case .some(.failure(let error)) where error is CancellationError:
			status = .cancelled
			reason = error.localizedDescription
		case .some(.failure(let error)):
			status = .failed
			reason = error.localizedDescription
		case .none:
			status = .cancelled
			reason = nil
		}
		return OperationOutcomeRecord(
			correlationID: correlationID,
			operation: "sign",
			stage: "sign",
			status: status,
			reason: reason,
			startedAt: startedAt,
			finishedAt: Date()
		)
	}

	private static func _perform(_ app: AppInfoPresentable, overridingBlockingIssues: Bool, repeatInstall: Bool) async -> Result<Signed, Error> {
		let stored = SigningProfileStore.shared.profile(forBundleID: app.identifier)
		let options = (stored?.options ?? Options.batchBase).resolved(for: app)
		let certificate = SigningProfileStore.shared.certificate(for: stored) ?? _certificate()

		// Check after waiting for earlier jobs: the saved identity may have been removed.
		if repeatInstall {
			guard app.isSigned, let id = app.identifier, !id.isEmpty,
			      options.signingOption == .default, (options.appIdentifier ?? id) == id,
			      let pinned = stored?.certificateUUID, !pinned.isEmpty,
			      certificate?.uuid?.lowercased() == pinned.lowercased(),
			      certificate?.revoked == false, let expiry = certificate?.expiration, expiry > Date()
			else { return .failure(AutoSignError.repeatInputsUnavailable) }
		}

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
			PackageSigningCoordinator.signPackage(
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

		if repeatInstall || options.post_installAppAfterSigned {
			InstallQueue.shared.enqueue(signed)
		}

		return result
	}

	nonisolated private static func _certificate() -> CertificatePair? {
		Storage.shared.getCertificate(for: UserDefaults.standard.integer(forKey: "vexsign.selectedCert"))
	}
}

extension AutoSignManager {
	/// The import button titles and symbols used by the Feather-family workflow: a plain
	/// download when auto sign is off, "Sign" when it is on, and "Sign & Install" when the
	/// saved signing options include installation. The exact strings are shared with the
	/// batch picker so both surfaces make the same promise.
	enum Action: String, CaseIterable {
		case keep
		case sign
		case install

		static var current: Self {
			guard isEnabled else { return .keep }
			return OptionsManager.shared.options.post_installAppAfterSigned ? .install : .sign
		}

		var title: String {
			switch self {
			case .keep: .localized("Add to Library")
			case .sign: .localized("Sign")
			case .install: .localized("Sign & Install")
			}
		}

		var systemImage: String {
			switch self {
			case .keep: "square.and.arrow.down"
			case .sign: "signature"
			case .install: "square.and.arrow.down.on.square"
			}
		}
	}
}

enum AutoSignError: LocalizedError {
	case noCertificate
	case repeatInputsUnavailable

	var errorDescription: String? {
		switch self {
		case .repeatInputsUnavailable: return .localized("Choose a signed library copy with an unchanged bundle ID and a saved, current certificate. Review its signing settings in VexSign.")
		case .noCertificate: return .localized("Auto sign needs a certificate. Import one in Settings, or turn auto sign off.")
		}
	}
}
