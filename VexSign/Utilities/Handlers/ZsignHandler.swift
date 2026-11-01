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

		try run(request)
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
			throw SigningFileHandlerError.signFailed
		}
	}
}
