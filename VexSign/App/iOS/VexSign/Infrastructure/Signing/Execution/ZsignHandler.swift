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
    private let engine: any SigningEngine
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
    var authorization: SigningResolutionAuthorization?
    var originalRequirements: [String: [String: Any]]?
    var originalSourceFingerprint: String?
    private(set) var verificationAssets: [String: SignatureVerifier.AssetExpectation] = [:]
    private(set) var resolutionReview: SigningResolutionReview?

	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil,
        executionGate: SigningExecutionGate,
        engine: any SigningEngine = ZsignAdapter()
	) {
		self.executionGate = executionGate
        self.engine = engine
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
        try await executionGate.withAsyncPermit {
            let inventory = try await MainActor.run { try SigningIdentityStore.leasedSnapshot() }
            defer { withExtendedLifetime(inventory.leases) {} }
            let preferred = await MainActor.run { self._certificate?.objectID.uriRepresentation().absoluteString }
            let device = PairingBridge.inspectPairingRecord().udid
            let prepared = try SigningResolutionSession.prepare(bundle: self._appUrl, options: self._options,
                inventory: inventory.inputs, preferredIdentity: preferred, deviceUDID: device,
                authorization: self.authorization, originalRequirements: self.originalRequirements,
                originalSourceFingerprint: self.originalSourceFingerprint)
            defer {
                do { try FileManager.default.removeItem(at: prepared.workspace) }
                catch { SigningLog.shared.warn("Protected signing inputs will be removed with the working directory.") }
            }
            self.resolutionReview = prepared.review
            self.verificationAssets = prepared.assets
            let captured = StdoutCapture.shared.start { SigningLog.shared.info($0) }
            defer { if captured { StdoutCapture.shared.stop() } }
            let references = Set(prepared.review.components.compactMap(\.identityReference))
            try await MainActor.run { try SigningIdentityStore.requireCurrent(references, matching: inventory.inputs) }
            guard PairingBridge.inspectPairingRecord().udid == device else { throw SigningResolutionSession.changedSinceReview() }
            guard prepared.validUntil > Date() else { throw ProvisioningProfileParser.Failure.expired }
            try Task.checkCancellation()
            try self.run(prepared.request)
        }
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
            // This worker-side check is shared by certificate, ad-hoc, batch and automation.
            // It inspects the modified tree after extension removal, not an earlier source snapshot.
            try BundleExecutableAudit.requireSignable(self._appUrl)
            let captured = StdoutCapture.shared.start { SigningLog.shared.info($0) }
            if !captured {
                SigningLog.shared.warn(.localized(
                    "Another signing run already owns engine output capture; this run's log will be incomplete."
                ))
            }
            defer { if captured { StdoutCapture.shared.stop() } }
            try self.run(request)
        }
    }

	// MARK: - Private

	/// Hands one request to the engine and turns its two failure signals into a thrown error.
	private func run(_ request: ZsignEngine.Request) throws {
		// The pinned engine writes its cache into the working directory and never reads it back
		// (see `ZsignEngine.clearCache`), so clearing it first cannot lose a cache hit and keeps
		// a stale entry from an earlier run out of the way.
		ZsignEngine.clearCache()

		let outcome = engine.sign(request)

        do { try outcome.requireSuccess() }
        catch {
            hadError = error
            throw error
        }
	}
}
