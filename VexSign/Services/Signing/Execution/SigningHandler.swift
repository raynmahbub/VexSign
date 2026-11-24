//
//  SigningHandler.swift
//  VexSign
//
//  Created by VexSign Contributors on 17.04.2025.
//

import CoreData
import CoreGraphics
import Foundation
import ImageIO
import Zsign
import OSLog
import NimbleExtensions

private struct SigningCleanupFailure: LocalizedError {
    let details: [String]

    var errorDescription: String? {
        "Could not remove signing work files: " + details.joined(separator: "; ")
    }
}

final class SigningHandler: NSObject {
	private let _fileManager = FileManager.default
    private let executionGate: SigningExecutionGate
	private let _uuid = UUID().uuidString
	/// Says, for as long as this run lives, that the copy `_uuid` names is being produced. Its
	/// bundle is in the library before its row is, and without this a cleanup pass in between
	/// takes the folder for a leftover and deletes it.
	private let _outputClaim: AppOperationRegistry.Lease
	private var _movedAppPath: URL?
    private var _ownsUniqueWorkDir = false
    private var _ownsSignedDirectory = false
	// using uuid string is the best way to find the
	// app we want to sign, it does not matter what
	// type of app it is
	private let _app: SigningAppSnapshot
	private var _options: Options
	private let _uniqueWorkDir: URL
	/// Encoded by the UI-side request before crossing into detached work.
	var appIconData: Data?
	/// Opaque Core Data identity; resolved only inside MainActor-isolated persistence calls.
	var appCertificateID: String?
    var authorization: SigningResolutionAuthorization?
    private var originalRequirements: [String: [String: Any]]?
    private var originalSourceFingerprint: String?
	// Original bundle id, captured before PPQ protection / any modifications.
	private var _originalBundleIdentifier: String?
	private var _appDescription: String?
	private var _didAddToDatabase = false
	private(set) var signedArtifact: LibraryAppReference?
	/// What the post-sign inspection found. Written before the bundle is moved into the
	/// library, so it describes the bytes that are actually kept.
	private(set) var verification: SignatureVerifier.Report?
	/// True when the run was started from the preflight sheet's "Sign Anyway". That accepts
    /// the preflight findings the sheet allows past; it does not relax the nested-bundle
    /// audit or the post-sign check, which reject the output on any failure.
	var overridesBlockingPreflightIssues = false
	/// Called as each stage begins. Synchronous on purpose: it is delivered to
	/// `SigningService`'s event queue, which preserves order.
	var onStage: ((SigningStage) -> Void)?
	/// Reports the exact extension bundles removed by compatibility mode.
	var onCompatibilityRemoved: (([String]) -> Void)?
	/// Reports that the engine's own signature verification accepted the bundle.
	///
	/// Separate from `onStage`: reaching `.verifying` only says the check started, and a
	/// "modify without signing" run reaches `.registering` without verifying anything.
	var onSignatureVerified: (() -> Void)?
	
	init(app: SigningAppSnapshot, options: Options, executionGate: SigningExecutionGate) {
        self.executionGate = executionGate
		self._app = app
		self._options = options
		self._appDescription = app.appDescription
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("VexSigning_\(_uuid)", isDirectory: true)
		self._outputClaim = AppOperationRegistry.shared.claimProduction(of: _uuid)
		super.init()
	}
	
	func copy() async throws {
        try Task.checkCancellation()
        onStage?(.copying)

		guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
			throw SigningFileHandlerError.appNotFound
		}

        // Unique per-run directory creation is exclusive: a pre-existing path is never reused.
        try _fileManager.createDirectory(at: _uniqueWorkDir, withIntermediateDirectories: false)
        _ownsUniqueWorkDir = true
        guard CleanupRemovalPolicy.isSafeDirectory(_uniqueWorkDir, beneath: _fileManager.temporaryDirectory) else {
            throw SigningCleanupFailure(details: ["The signing work directory failed its ownership check."])
        }

		let movedAppURL = _uniqueWorkDir.appendingPathComponent(appUrl.lastPathComponent)

        try StoragePreflight.checkBundle(appUrl, copies: 2, destination: _uniqueWorkDir)
		try _fileManager.copyItem(at: appUrl, to: movedAppURL)
        _movedAppPath = movedAppURL
        if _options.signingOption == .default {
            let source = try SigningResolutionSession.sourceFingerprint(in: movedAppURL)
            if let authorization, authorization.sourceFingerprint != source {
                throw SigningResolutionSession.changedSinceReview(.sourceBundle)
            }
            originalSourceFingerprint = source
            originalRequirements = try SigningResolutionSession.requirements(in: movedAppURL, options: _options)
        }

		// A cancel during a large copy is common enough to check for straight away.
		try Task.checkCancellation()
		SigningLog.shared.info(.localized("Copied app bundle"))

		// Capture the original bundle id BEFORE any modifications (PPQ protection, etc.).
		if let bundle = Bundle(url: movedAppURL) {
			_originalBundleIdentifier = bundle.bundleIdentifier
			Logger.misc.info("[\(self._uuid)] Captured original bundle ID: \(bundle.bundleIdentifier ?? "nil")")
		}

		Logger.misc.info("[\(self._uuid)] Moved Payload to: \(movedAppURL.path)")
	}
	
	func modify() async throws {
		onStage?(.modifying)

		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}

		try Task.checkCancellation()
		
		let infoPlistURL = movedAppPath.appendingPathComponent("Info.plist")
		guard
			let infoData = try? Data(contentsOf: infoPlistURL),
			let plistObject = try? PropertyListSerialization.propertyList(from: infoData, options: .mutableContainersAndLeaves, format: nil),
			let infoDictionary = plistObject as? NSMutableDictionary
		else {
			throw SigningFileHandlerError.infoPlistNotFound
		}
		
		SigningLog.shared.info(.localized("Applying modifications"))

		if
			let identifier = _options.effectiveAppIdentifier,
			let oldIdentifier = infoDictionary["CFBundleIdentifier"] as? String {
			SigningLog.shared.info(.localized("Changing bundle identifier to %@", arguments: identifier))
			try await _modifyPluginIdentifiers(old: oldIdentifier, new: identifier, for: movedAppPath)
		}

		try await _modifyDict(using: infoDictionary, with: _options, to: movedAppPath)

		if let version = _options.appVersion {
			SigningLog.shared.info(.localized("Setting version to %@", arguments: version))
		}

			if let iconData = appIconData {
				SigningLog.shared.info(.localized("Replacing app icon"))
				try _modifyDict(using: infoDictionary, forImageData: iconData, to: movedAppPath)
			}

		if let name = _options.appName {
			SigningLog.shared.info(.localized("Renaming app to %@", arguments: name))
			try await _modifyLocalesForName(name, for: movedAppPath)
		}

		if !_options.removeFiles.isEmpty {
			SigningLog.shared.info(.localized("Removing bundled files"))
			try await _removeFiles(for: movedAppPath, from: _options.removeFiles)
		}

		try await _removePresetFiles(for: movedAppPath)
        // Device-signing removals are planned/confirmed and applied only in the
        // final resolver gate. They never use just the selected profile's pattern.
        if _options.signingOption == .onlyModify { try await _removeAppExtensionsIfNeeded(for: movedAppPath) }

		if _options.experiment_supportLiquidGlass {
			SigningLog.shared.info(.localized("Patching for Liquid Glass"))
			try await _locateMachosAndChangeToSDK26(for: movedAppPath)
		}

		if _options.thinMachOBinaries {
			onStage?(.thinning)
			SigningLog.shared.info(.localized("Thinning Mach-O binaries to ARM64"))
			try await _locateMachosAndThin(for: movedAppPath)
			try Task.checkCancellation()
		}

		let hasTweakSpecs = !(_options.tweakInjections ?? []).filter { $0.enabled }.isEmpty
		if _options.experiment_replaceSubstrateWithEllekit {
			onStage?(.injecting)
			SigningLog.shared.info(.localized("Injecting tweaks"))
			try await _inject(for: movedAppPath, with: _options)
			try Task.checkCancellation()
		} else {
			if !_options.injectionFiles.isEmpty || hasTweakSpecs || _options.fixFilePicker {
				onStage?(.injecting)
				SigningLog.shared.info(.localized("Injecting tweaks"))
				try await _inject(for: movedAppPath, with: _options)
				try Task.checkCancellation()
			}
		}
		
		// iOS "26" (19) needs special treatment
		try await _locateMachosAndFixupArm64eSlice(for: movedAppPath)

        // Required entitlements were captured before binary surgery. JIT and
        // explicit keychain changes are planned and authorized per component;
        // they no longer copy the entire selected profile or drop unknown keys.

		let handler = ZsignHandler(appUrl: movedAppPath, options: _options, certificateID: appCertificateID, executionGate: executionGate)
        handler.authorization = authorization
        handler.originalRequirements = originalRequirements
        handler.originalSourceFingerprint = originalSourceFingerprint
		try await handler.disinject()

		// Customization ends here. What follows decides whether the selected certificate and
		// profile can sign this bundle at all, so that is where a refusal has to be reported.
		// The stage used to be announced only once zsign started, which put a profile that does
		// not cover a retained extension, or a missing certificate, on the Customize step: the
		// workflow read "Customize: Failed, Sign: Not run" for a bundle whose customization had
		// in fact finished. Modify-only runs never sign, so they still never report this stage.
		if _options.signingOption == .default {
			onStage?(.signing)
		}

        // The execution gate validates every retained component, including
        // nested identities and entitlements, against the actual modified tree.

        if _options.signingOption == .default {
            guard let certName = await _certificateDisplayName() else { throw SigningFileHandlerError.missingCertifcate }
			SigningLog.shared.info(.localized("Signing with %@", arguments: certName))
			try await handler.sign()
            if let reference = handler.resolutionReview?.mainIdentityReference {
                try await _selectResolvedCertificate(reference: reference)
            }
            if let removed = handler.resolutionReview?.plannedRemovals, !removed.isEmpty {
                onCompatibilityRemoved?(removed)
                for path in removed { SigningLog.shared.warn("Explicit compatibility removal: " + path) }
            }
		} else if _options.signingOption == .onlyModify {
			SigningLog.shared.info(.localized("Modifying without signing"))
		} else {
			throw SigningFileHandlerError.missingCertifcate
		}
		
        try Task.checkCancellation()
        if let error = handler.hadError {
			throw error
		}

		if _options.signingOption == .default {
			onStage?(.verifying)
			try _verifySignedBundle(at: movedAppPath, assets: handler.verificationAssets)
			// `_verifySignedBundle` throws when the report is unacceptable, so returning from
			// it is the engine's own evidence that verification passed. Reported here and only
			// here: a "modify without signing" run never reaches this line.
            // Only complete independently authenticated evidence is accepted
            // for fresh device-signing output.
			if verification?.verdict.isVerified == true {
				onSignatureVerified?()
			}
		}

		// Past this point the run is either registered or cleaned up by `clean()`; a cancel here
		// must not leave a bundle in the library that no row points at.
		try Task.checkCancellation()

		try await self.move()

		onStage?(.registering)
		try Task.checkCancellation()

		try await self.addToDatabase()
		
        if _options.signingOption == .default { await AnalyticsStore.shared.record(.appsSigned) }
        let injectedCount = _options.injectionFiles.count + (_options.tweakInjections ?? []).filter { $0.enabled }.count
        if injectedCount > 0 { await AnalyticsStore.shared.record(.tweaksInjected, count: injectedCount) }
    }
	
    /// Resolve only at the point of use; a managed certificate never lives in worker state.
    @MainActor
    private func _certificateDisplayName() -> String? {
        guard let appCertificateID,
              let certificate = try? Storage.shared.managedCertificate(id: appCertificateID),
              !certificate.isDeleted else { return nil }
        return certificate.nickname ?? Storage.shared.getProvisionFileDecoded(for: certificate)?.Name ?? .localized("certificate")
    }

    @MainActor
    private func _selectResolvedCertificate(reference: String) throws {
        _ = try Storage.shared.managedCertificate(id: reference)
        appCertificateID = reference
    }

    /// The final check on what was produced. Any failure stops the run before library
    /// registration or a success event: a bundle that failed here cannot be installed, so it
    /// is not kept, whether or not the preflight sheet was confirmed.
	private func _verifySignedBundle(at path: URL, assets: [String: SignatureVerifier.AssetExpectation]) throws {
		var expectation = SignatureVerifier.Expectation.freshlySigned
		expectation.declaredBundleIdentifier = _options.effectiveAppIdentifier
		expectation.requiresEmbeddedProfile = true
        expectation.assets = assets

		let report = SignatureVerifier.verify(bundleAt: path, expectation: expectation)
		verification = report

		for issue in report.failures {
			SigningLog.shared.error(.localized("Signature check: %@", arguments: issue.detail))
		}
		for issue in report.warnings {
			SigningLog.shared.warn(.localized("Signature check: %@", arguments: issue.detail))
		}

		switch report.verdict {
		case .valid:
			SigningLog.shared.success(report.summary)
		case .incomplete:
            // A fresh device signature is never registered on incomplete evidence.
			SigningLog.shared.warn(report.summary)
			SigningLog.shared.warn(.localized("Some signing evidence could not be read, so the checks that depend on it did not run."))
		case .invalid, .unsupported:
            SigningLog.shared.error(report.summary)
        }
        try report.requireVerified()
    }

	func move() async throws {
		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}
		
        let signedRoot = _fileManager.signed
        try _fileManager.createDirectory(at: signedRoot, withIntermediateDirectories: true)
        guard CleanupRemovalPolicy.isSafeDirectory(signedRoot, beneath: URL.documentsDirectory) else {
            throw CleanupRemovalPolicy.Rejection.unsafeTarget
        }
        let signedDirectory = try await _directory()
        try _fileManager.createDirectory(at: signedDirectory, withIntermediateDirectories: false)
        _ownsSignedDirectory = true
        guard CleanupRemovalPolicy.isSafeDirectory(signedDirectory, beneath: signedRoot) else {
            throw CleanupRemovalPolicy.Rejection.unsafeTarget
        }

        let destinationURL = signedDirectory.appendingPathComponent(movedAppPath.lastPathComponent)
        try _fileManager.moveItem(at: movedAppPath, to: destinationURL)
        LibrarySizeSnapshot.invalidate()
		Logger.misc.info("[\(self._uuid)] Moved App to: \(destinationURL.path)")

        // `clean()` owns the work directory removal so a failure can be surfaced and retried.
	}
	
	/// Runs on the main actor: it ends by handing a managed object to the caller and
	/// `NSManagedObject` is not `Sendable`. The write itself hops to the private
	/// queue; only the row lookup comes back here.
	@MainActor
	func addToDatabase() async throws {
		let app = try await _directory()

        guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
            throw SigningFileHandlerError.appNotFound
        }
        // Registration is the commit point. A cancellation before it must leave no row.
        try Task.checkCancellation()

        guard let bundle = Bundle(url: appUrl),
              let identifier = SignatureVerifier.readInfo(at: appUrl)?["CFBundleIdentifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              SigningInputValidation.executable(in: appUrl) != nil else {
            throw SigningFileHandlerError.appNotFound
        }
		// Only a `.default` run is signed with the selected certificate; modify-only
		// output remains certificate-free. Resolve the opaque URI on MainActor, then
		// pass only Core Data's immutable object ID to the write context.
		let certificateID: NSManagedObjectID?
		if _options.signingOption == .default {
			guard let appCertificateID else { throw SigningFileHandlerError.missingCertifcate }
			certificateID = try Storage.shared.managedCertificate(id: appCertificateID).objectID
		} else {
			certificateID = nil
		}

		let objectID = try await Storage.shared.addSigned(
			uuid: _uuid,
			source: _app.source,
			certificateID: certificateID,
			appName: bundle.name,
            appIdentifier: identifier,
			originalAppIdentifier: _originalBundleIdentifier,
			appVersion: bundle.version,
            appIcon: bundle.iconFileName,
			appDescription: _appDescription
		)

		Logger.signing.info("[\(self._uuid)] Added to database (original ID: \(self._originalBundleIdentifier ?? "nil"), current ID: \(identifier))")

        // Resolve the exact committed row by its permanent ID on the view context.
        // The row is already committed. Preserve its bundle even if resolving it fails,
        // rather than leaving a saved row pointing at a deleted directory.
        _didAddToDatabase = true
        // The same goes for cleanup: a pass that read the library before this commit does not
        // know the row, and the claim ends with this run.
        AppOperationRegistry.shared.confirmProduction(of: _uuid)
        guard let registered: Signed = Storage.shared.object(objectID) else {
            throw SigningFileHandlerError.appNotFound
        }
        signedArtifact = try LibraryAppReference(app: registered)
	}
	
	private func _directory() async throws -> URL {
		// Documents/App/iOS/VexSign/Signed/\(UUID)
		_fileManager.signed(_uuid)
	}
	
	func clean() async throws {
        var failures: [Error] = []
        if _ownsUniqueWorkDir {
            do {
                _ = try CleanupRemovalPolicy.remove(_uniqueWorkDir, beneath: _fileManager.temporaryDirectory)
                _ownsUniqueWorkDir = false
            } catch {
                failures.append(error)
            }
        }
        // A moved-but-unregistered bundle is unreachable from the library, so it would leak forever.
        // Once the row commits, never delete this directory, even if resolving the row then fails.
        if !_didAddToDatabase && _ownsSignedDirectory {
            do {
                _ = try CleanupRemovalPolicy.remove(_fileManager.signed(_uuid), beneath: _fileManager.signed)
                _ownsSignedDirectory = false
            } catch {
                failures.append(error)
            }
        }
        if !failures.isEmpty {
            throw SigningCleanupFailure(details: failures.map { LogRedaction.redact($0.localizedDescription) })
        }
	}
}

extension SigningHandler {
	private func _modifyDict(using infoDictionary: NSMutableDictionary, with options: Options, to app: URL) async throws {
		if options.infoPlistChangeCount > 0 {
			SigningLog.shared.info(.localized("Applying custom Info.plist changes"))
		}

		InfoPlistPlan.apply(options, to: infoDictionary)

		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _modifyDict(using infoDictionary: NSMutableDictionary, forImageData imageData: Data, to app: URL) throws {
		let imageSizes = [
			(width: 120, height: 120, name: "FRIcon60x60@2x.png"),
			(width: 152, height: 152, name: "FRIcon76x76@2x~ipad.png")
		]
		let thumbnailOptions: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: 2048
		]
		guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
			  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
		else { throw SigningFileHandlerError.signFailed }

		for imageSize in imageSizes {
			let scale = min(CGFloat(imageSize.width) / CGFloat(image.width), CGFloat(imageSize.height) / CGFloat(image.height))
			let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
			let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
			guard let context = CGContext(
				data: nil,
				width: width,
				height: height,
				bitsPerComponent: 8,
				bytesPerRow: 0,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			) else { throw SigningFileHandlerError.signFailed }
			context.interpolationQuality = .high
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			guard let resized = context.makeImage() else { throw SigningFileHandlerError.signFailed }

			let encoded = NSMutableData()
			guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
				throw SigningFileHandlerError.signFailed
			}
			CGImageDestinationAddImage(destination, resized, nil)
			guard CGImageDestinationFinalize(destination) else { throw SigningFileHandlerError.signFailed }
			try (encoded as Data).write(to: app.appendingPathComponent(imageSize.name))
		}
		
		let cfBundleIcons: [String: Any] = [
			"CFBundlePrimaryIcon": [
				"CFBundleIconFiles": ["FRIcon60x60"],
				"CFBundleIconName": "FRIcon"
			]
		]
		
		let cfBundleIconsIpad: [String: Any] = [
			"CFBundlePrimaryIcon": [
				"CFBundleIconFiles": ["FRIcon60x60", "FRIcon76x76"],
				"CFBundleIconName": "FRIcon"
			]
		]
		
		infoDictionary["CFBundleIcons"] = cfBundleIcons
		infoDictionary["CFBundleIcons~ipad"] = cfBundleIconsIpad
		
		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _modifyLocalesForName(_ name: String, for app: URL) async throws {
		let localizationBundles = try _fileManager
			.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "lproj" }
		
		localizationBundles.forEach { bundleURL in
			let plistURL = bundleURL.appendingPathComponent("InfoPlist.strings")
			
			guard
				_fileManager.fileExists(atPath: plistURL.path),
				let dictionary = NSMutableDictionary(contentsOf: plistURL)
			else {
				return
			}
			
			dictionary["CFBundleDisplayName"] = name
			dictionary.write(toFile: plistURL.path, atomically: true)
		}
	}
	
	private func _modifyPluginIdentifiers(
		old oldIdentifier: String,
		new newIdentifier: String,
		for app: URL
	) async throws {
		// Rewrite all nested bundles, including retained Watch apps even when the
		// user chose to remove app extensions. Removed extensions are stripped later.
		let pluginBundles = _enumerateFiles(at: app) {
			$0.hasSuffix(".app") || $0.hasSuffix(".appex")
		}
		
		for bundleURL in pluginBundles {
			let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
			
			guard let infoDict = NSDictionary(contentsOf: infoPlistURL)?.mutableCopy() as? NSMutableDictionary else {
				continue
			}
			
			var didChange = false
			
			// CFBundleIdentifier
			if let oldValue = infoDict["CFBundleIdentifier"] as? String {
				let newValue = NestedBundleAudit.rewrittenIdentifier(oldValue, from: oldIdentifier, to: newIdentifier)
				if oldValue != newValue {
					infoDict["CFBundleIdentifier"] = newValue
					didChange = true
				}
			}
			
			// WKCompanionAppBundleIdentifier
			if let oldValue = infoDict["WKCompanionAppBundleIdentifier"] as? String {
				let newValue = NestedBundleAudit.rewrittenIdentifier(oldValue, from: oldIdentifier, to: newIdentifier)
				if oldValue != newValue {
					infoDict["WKCompanionAppBundleIdentifier"] = newValue
					didChange = true
				}
			}
			
			if let extensionDict = (infoDict["NSExtension"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary {
				// NSExtension → NSExtensionAttributes → WKAppBundleIdentifier
				if
					let attributes = extensionDict["NSExtensionAttributes"] as? NSMutableDictionary,
					let oldValue = attributes["WKAppBundleIdentifier"] as? String {
					let newValue = NestedBundleAudit.rewrittenIdentifier(oldValue, from: oldIdentifier, to: newIdentifier)
					if oldValue != newValue {
						attributes["WKAppBundleIdentifier"] = newValue
						didChange = true
					}
				}

				// NSExtension → NSExtensionFileProviderDocumentGroup
				if
					let oldValue = extensionDict["NSExtensionFileProviderDocumentGroup"] as? String {
					let newValue = NestedBundleAudit.rewrittenIdentifier(oldValue, from: oldIdentifier, to: newIdentifier)
					if oldValue != newValue {
						extensionDict["NSExtensionFileProviderDocumentGroup"] = newValue
						didChange = true
					}
				}

                infoDict["NSExtension"] = extensionDict
			}
			
			if didChange {
				infoDict.write(to: infoPlistURL, atomically: true)
			}
		}
	}
	
	private func _removePresetFiles(for app: URL) async throws {
		var files = [
			"_CodeSignature", // Fallback for some reason the locate doesnt work
			"embedded.mobileprovision", // Remove this because zsign doesn't replace it
			"com.apple.WatchPlaceholder", // Useless
			"SignedByEsign" // Useless
		].map {
			app.appendingPathComponent($0)
		}
		
		await files += try _locateCodeSignatureDirectories(for: app)
		
		for file in files {
			try _fileManager.removeFileIfNeeded(at: file)
		}
	}
	
	// Removes every .appex from PlugIns/ and Extensions/ — only when opted in via `removeAppExtensions`.
	// Default (false) keeps them so widget/share/action extensions survive signing and stay installable.
	private func _removeAppExtensionsIfNeeded(for app: URL) async throws {
		guard _options.removeAppExtensions else { return }

		let appexes = AppExtensionEnumerator.appexBundles(in: app)
		guard !appexes.isEmpty else { return }

		SigningLog.shared.info(.localized("Removing %lld app extension(s)", arguments: appexes.count))
        for appex in appexes {
            let path = String(appex.path.dropFirst(app.path.count + 1))
            guard try OptionalExtensionPolicy.canRemove(path, in: app) else {
                throw SigningFileHandlerError.identityRejected("This extension cannot be safely removed: " + path)
            }
            try _fileManager.removeFileIfNeeded(at: appex)
			Logger.misc.info("[\(self._uuid)] Removed app extension: \(appex.lastPathComponent)")
		}
	}

	// horrible edge-case

	private func _removeFiles(for app: URL, from appendingComponent: [String]) async throws {
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        // Validate the complete user-specified list before changing the work
        // tree. A relative customization cannot escape into a source IPA,
        // another version, shared identity, or any other container directory.
        let filesToRemove = try appendingComponent.map { path -> URL in
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."),
                  url.path.hasPrefix(root.path + "/"),
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw SigningFileHandlerError.identityRejected("A requested file removal escapes the signing working copy. No such file has been removed.")
            }
            return url
        }
        for url in filesToRemove { try _fileManager.removeFileIfNeeded(at: url) }
	}
	
	private func _inject(for app: URL, with options: Options) async throws {
		let handler = TweakHandler(app: app, options: options)
		try await handler.getInputFiles()
	}
	
	private func _locateMachosAndChangeToSDK26(for app: URL) async throws {
		if let url = Bundle(url: app)?.executableURL {
			LCPatchMachOForSDK26(app.appendingPathComponent(url.relativePath).relativePath)
		}
	}

	private func _locateMachosAndThin(for app: URL) async throws {
		let candidates = _enumerateFiles(at: app) { file in
			file.hasSuffix(".dylib") || file.hasSuffix(".framework") || !file.contains(".")
		}

		for fileURL in candidates {
			switch fileURL.pathExtension {
			case "dylib":
				_ = LCThinMachOToARM64(fileURL.path)
			case "framework":
				if let bundle = Bundle(url: fileURL), let execURL = bundle.executableURL {
					_ = LCThinMachOToARM64(execURL.path)
				}
			default:
				var isDir: ObjCBool = false
				if _fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
					_ = LCThinMachOToARM64(fileURL.path)
				}
			}
		}

		if let mainExec = Bundle(url: app)?.executableURL {
			_ = LCThinMachOToARM64(mainExec.path)
		}
	}
	
	private func _locateCodeSignatureDirectories(for app: URL) async throws -> [URL] {
		_enumerateFiles(at: app) { $0.hasSuffix("_CodeSignature") }
	}
	
	private func _locateMachosAndFixupArm64eSlice(for app: URL) async throws {
		let machoFiles = _enumerateFiles(at: app) {
			$0.hasSuffix(".dylib") || $0.hasSuffix(".framework")
		}
		
		for fileURL in machoFiles {
			switch fileURL.pathExtension {
			case "dylib":
				LCPatchMachOFixupARM64eSlice(fileURL.path)
			case "framework":
				if
					let bundle = Bundle(url: fileURL),
					let execURL = bundle.executableURL {
					LCPatchMachOFixupARM64eSlice(execURL.path)
				}
			default:
				continue
			}
		}
	}
	
	private func _enumerateFiles(at base: URL, where predicate: (String) -> Bool) -> [URL] {
		guard let fileEnum = _fileManager.enumerator(atPath: base.path) else {
			return []
		}
		
		var results: [URL] = []
		
		while let file = fileEnum.nextObject() as? String {
			if predicate(file) {
				results.append(base.appendingPathComponent(file))
			}
		}
		
		return results
	}
}

enum SigningFileHandlerError: Error, LocalizedError {
	case appNotFound
	case infoPlistNotFound
	case missingCertifcate
	case disinjectFailed
	/// The engine declined before it had a bundle to complain about, and named no reason of its
	/// own: usually a certificate/profile pair it cannot use. `identityRejected` says which.
	case engineRefused
	/// The identity cannot sign anything, in the engine's own terms — see
	/// `ZsignEngine.IdentityProblem`.
	case identityRejected(String)
	case entitlementsUnreadable
	case signFailed

	var errorDescription: String? {
		switch self {
		case .appNotFound: "Unable to locate bundle path."
		case .infoPlistNotFound: "Unable to locate info.plist path."
		case .missingCertifcate: "No certificate was specified."
		case .disinjectFailed: "Removing mach-O load paths failed."
		case .engineRefused:
			.localized("Signing failed: the engine refused this app and did not say why. Open the signing log for its output.")
		case .identityRejected(let reason): reason
		case .entitlementsUnreadable:
			.localized("The custom entitlements file must be a readable property-list dictionary.")
		case .signFailed: "Signing failed."
		}
	}
}
