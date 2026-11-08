//
//  ZsignHandler.swift
//  VexSign
//
//  Created by VexSign Team on 17.04.2025.
//

import Foundation
import OSLog
import UIKit
import NimbleExtensions

final class ZsignHandler {
	var hadError: Error?

	private let executionGate: SigningExecutionGate
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?

	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil,
        executionGate: SigningExecutionGate
	) {
		self.executionGate = executionGate
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
	}

	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}

		SigningLog.shared.info(.localized("Removing injected dylibs"))

        guard let executable = SigningInputValidation.executable(in: _appUrl) else {
            throw SigningFileHandlerError.appNotFound
        }
        try await executionGate.withPermit {
            guard ZsignEngine.removeInjectedDylibs(_options.disInjectionFiles, fromExecutableAt: executable.path) else {
                throw SigningFileHandlerError.disinjectFailed
            }
        }
	}

	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

		var request = ZsignEngine.Request(appPath: _appUrl.relativePath)
		request.provisionPath = Storage.shared.getFile(.provision, from: cert)?.path ?? ""
		request.p12Path = Storage.shared.getFile(.certificate, from: cert)?.path ?? ""
		request.p12Password = try cert.requireSigningPassword()
		request.entitlementsPath = _options.appEntitlementsFile?.path ?? ""
		request.removeProvisioning = _options.removeProvisioning

		try _rejectRefusedIdentity(for: cert, provisionPath: request.provisionPath, p12Path: request.p12Path)
        try await _runExclusively(request)
	}

	func adhocSign() async throws {
		var request = ZsignEngine.Request(
			appPath: _appUrl.relativePath,
			isAdHoc: true,
			removeProvisioning: _options.removeProvisioning
		)
		request.entitlementsPath = _options.appEntitlementsFile?.path ?? ""

        try await _runExclusively(request)
	}

    /// Validate custom entitlements for both certificate and ad-hoc requests. Capture and
    /// cache cleanup must start only after acquiring native-engine ownership.
    private func _runExclusively(_ request: ZsignEngine.Request) async throws {
        guard SigningInputValidation.executable(in: _appUrl) != nil else {
            throw SigningFileHandlerError.appNotFound
        }
        guard SigningInputValidation.entitlementsAreUsable(at: request.entitlementsPath) else {
            throw SigningFileHandlerError.entitlementsUnreadable
        }
        try await executionGate.withPermit {
            // Recheck after waiting: inputs may have changed while queued.
            guard SigningInputValidation.executable(in: self._appUrl) != nil else {
                throw SigningFileHandlerError.appNotFound
            }
            guard SigningInputValidation.entitlementsAreUsable(at: request.entitlementsPath) else {
                throw SigningFileHandlerError.entitlementsUnreadable
            }
            StdoutCapture.shared.start { SigningLog.shared.info($0) }
            defer { StdoutCapture.shared.stop() }
            try self.run(request)
        }
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

        do { try outcome.requireSuccess() }
        catch {
            hadError = error
            throw error
        }
	}
}
