//
//  ZsignHandler.swift
//  VexSign
//
//  Created by VexSign Team on 17.04.2025.
//

import Foundation
import UIKit
import NimbleExtensions

final class ZsignHandler {
	var hadError: Error?

	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?

	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
	}

	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}

		SigningLog.shared.info(.localized("Removing injected dylibs"))

		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath

		if !ZsignEngine.removeInjectedDylibs(_options.disInjectionFiles, fromExecutableAt: execPath) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}

	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

		StdoutCapture.shared.start { SigningLog.shared.info($0) }
		defer { StdoutCapture.shared.stop() }

		var request = ZsignEngine.Request(appPath: _appUrl.relativePath)
		request.provisionPath = Storage.shared.getFile(.provision, from: cert)?.path ?? ""
		request.p12Path = Storage.shared.getFile(.certificate, from: cert)?.path ?? ""
		request.p12Password = try cert.requireSigningPassword()
		request.entitlementsPath = _options.appEntitlementsFile?.path ?? ""
		request.removeProvisioning = _options.removeProvisioning

		try _rejectRefusedIdentity(for: cert, provisionPath: request.provisionPath, p12Path: request.p12Path)
		try run(request)
	}

	func adhocSign() async throws {
		StdoutCapture.shared.start { SigningLog.shared.info($0) }
		defer { StdoutCapture.shared.stop() }

		var request = ZsignEngine.Request(
			appPath: _appUrl.relativePath,
			isAdHoc: true,
			removeProvisioning: _options.removeProvisioning
		)
		request.entitlementsPath = _options.appEntitlementsFile?.path ?? ""

		// Ad-hoc runs need no identity, so only the entitlements file can be unusable.
		if
			let path = _options.appEntitlementsFile?.path,
			!path.isEmpty,
			_data(at: path) == nil {
			throw SigningFileHandlerError.entitlementsUnreadable
		}

		try run(request)
	}

	// MARK: - Identity

	/// Asks the engine's own acceptance rules whether this identity can start a run.
	///
	/// `zsign` refuses a profile that does not belong to the .p12, an unreadable .p12, a
	/// missing profile and a profile without a team identifier — and reports none of that
	/// through its completion handler, so the run would otherwise end in the bare
	/// "Signing failed." this check replaces.
	private func _rejectRefusedIdentity(
		for cert: CertificatePair,
		provisionPath: String,
		p12Path: String
	) throws {
		let problem = ZsignEngine.identityProblem(
			provisioningProfile: _data(at: provisionPath),
			certificate: _data(at: p12Path),
			leafCertificate: cert.appliedCertificateDER,
			profile: cert.decodedProfile
		)
		guard let problem else { return }

		SigningLog.shared.error(.localized("Signing identity: %@", arguments: problem.message))
		throw SigningFileHandlerError.identityRejected(problem.message)
	}

	private func _data(at path: String) -> Data? {
		guard !path.isEmpty else { return nil }
		do {
			return try Data(contentsOf: URL(fileURLWithPath: path))
		} catch {
			Logger.misc.error("Could not read \(path): \(error.localizedDescription)")
			return nil
		}
	}

	// MARK: - Private

	/// Hands one request to the engine and turns its two failure signals into a thrown error.
	private func run(_ request: ZsignEngine.Request) throws {
		// The pinned engine writes its cache into the working directory and never reads it back
		// (see `ZsignEngine.clearCache`), so clearing it first cannot lose a cache hit and keeps
		// a stale entry from an earlier run out of the way.
		ZsignEngine.clearCache()

		let outcome = ZsignEngine.sign(request)

		if let message = outcome.errorMessage {
			let error = NSError(
				domain: "app.vexsign.zsign",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: message]
			)
			hadError = error
			throw error
		}
		if !outcome.succeeded {
			// No message: the engine gave up before it had a bundle to complain about, or it
			// failed a step it does not report. The log holds whatever it printed.
			throw SigningFileHandlerError.engineRefused
		}
	}
}
