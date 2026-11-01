//
//  SigningHandler.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 17.04.2025.
//

import Foundation
import Zsign
import UIKit
import OSLog
import NimbleExtensions

final class SigningHandler: NSObject {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private var _movedAppPath: URL?
	// using uuid string is the best way to find the
	// app we want to sign, it does not matter what
	// type of app it is
	private var _app: AppInfoPresentable
	private var _options: Options
	private let _uniqueWorkDir: URL
	// the options struct is not gonna decode these so
	// we're just going to do this. If appicon is not
	// specified, we're not going to modify the app
	// icon. If the cert pair is not there, fallback
	// to adhoc signing (if the option is on, otherwise
	// throw an error
	var appIcon: UIImage?
	var appCertificate: CertificatePair?
	// Original bundle id, captured before PPQ protection / any modifications.
	private var _originalBundleIdentifier: String?
	private var _appDescription: String?
	private var _didAddToDatabase = false
	private(set) var signedApp: Signed?
	/// What the post-sign inspection found. Written before the bundle is moved into the
	/// library, so it describes the bytes that are actually kept.
	private(set) var verification: SignatureVerifier.Report?
	/// Called as each stage begins. Synchronous on purpose: it is delivered to
	/// `SigningService`'s event queue, which preserves order.
	var onStage: ((SigningStage) -> Void)?
	
	init(app: AppInfoPresentable, options: Options = OptionsManager.shared.options) {
		self._app = app
		self._options = options
		self._appDescription = app.appDescription
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("VexSigning_\(_uuid)", isDirectory: true)
		super.init()
	}
	
	func copy() async throws {
		onStage?(.copying)

		guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
			throw SigningFileHandlerError.appNotFound
		}

		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)

		let movedAppURL = _uniqueWorkDir.appendingPathComponent(appUrl.lastPathComponent)

		try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		_movedAppPath = movedAppURL

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
			let identifier = _options.appIdentifier,
			let oldIdentifier = infoDictionary["CFBundleIdentifier"] as? String {
			SigningLog.shared.info(.localized("Changing bundle identifier to %@", arguments: identifier))
			try await _modifyPluginIdentifiers(old: oldIdentifier, new: identifier, for: movedAppPath)
		}

		try await _modifyDict(using: infoDictionary, with: _options, to: movedAppPath)

		if let version = _options.appVersion {
			SigningLog.shared.info(.localized("Setting version to %@", arguments: version))
		}

		if let icon = appIcon {
			SigningLog.shared.info(.localized("Replacing app icon"))
			try await _modifyDict(using: infoDictionary, for: icon, to: movedAppPath)
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
		try await _removeWatchIfNeeded(for: movedAppPath)
		// Opt-in only: default false leaves PlugIns/ and Extensions/ untouched.
		try await _removeAppExtensionsIfNeeded(for: movedAppPath)

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

		if _options.keychainIsolation {
			try await _isolateKeychainGroups(for: movedAppPath)
		}

		// Runs after keychain isolation so it layers on top of whatever that wrote.
		if _options.enableJIT {
			try _applyJITEntitlements()
		}

		// Before the long sign: which extensions the selected profile can actually cover. The
		// engine signs every nested bundle with the outer asset, so an extension the profile does
		// not cover cannot come out correctly — better said now than after the install.
		_auditNestedBundles(at: movedAppPath, certificate: appCertificate)

		let handler = ZsignHandler(appUrl: movedAppPath, options: _options, cert: appCertificate)
		try await handler.disinject()
		
		if
			_options.signingOption == .default,
			let cert = appCertificate {
			let certName = cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? .localized("certificate")
			onStage?(.signing)
			SigningLog.shared.info(.localized("Signing with %@", arguments: certName))
			try await handler.sign()
		} else if _options.signingOption == .onlyModify {
			SigningLog.shared.info(.localized("Modifying without signing"))
		} else {
			throw SigningFileHandlerError.missingCertifcate
		}
		
		if let error = handler.hadError {
			throw error
		}

		if _options.signingOption == .default {
			onStage?(.verifying)
			_verifySignedBundle(at: movedAppPath)
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
	
	/// Checks the bundle that zsign just produced. Nothing here throws: a signature problem is
	/// reported in the signing log and carried on `verification`, and the place that *acts* on
	/// it is the install path (`DirectInstaller`), which can show the user what is wrong.
	private func _verifySignedBundle(at path: URL) {
		var expectation = SignatureVerifier.Expectation.freshlySigned
		expectation.declaredBundleIdentifier = _options.appIdentifier
		expectation.requiresEmbeddedProfile = !_options.removeProvisioning

		let report = SignatureVerifier.verify(bundleAt: path, expectation: expectation)
		verification = report

		for issue in report.failures {
			SigningLog.shared.error(.localized("Signature check: %@", arguments: issue.detail))
		}
		for issue in report.warnings {
			SigningLog.shared.warn(.localized("Signature check: %@", arguments: issue.detail))
		}

		if report.isAcceptable {
			SigningLog.shared.success(report.summary)
		} else {
			SigningLog.shared.warn(report.summary)
		}
	}

	func move() async throws {
		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}
		
		var destinationURL = try await _directory()
		
		try _fileManager.createDirectoryIfNeeded(at: destinationURL)
		
		destinationURL = destinationURL.appendingPathComponent(movedAppPath.lastPathComponent)
		
		try _fileManager.moveItem(at: movedAppPath, to: destinationURL)
		Logger.misc.info("[\(self._uuid)] Moved App to: \(destinationURL.path)")
		
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}
	
	/// Runs on the main actor: it ends by handing a managed object to the caller and
	/// `NSManagedObject` is not `Sendable`. The write itself hops to the private
	/// queue; only the row lookup comes back here.
	@MainActor
	func addToDatabase() async throws {
		let app = try await _directory()

		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			return
		}

		let bundle = Bundle(url: appUrl)
		// Only a `.default` run is signed with the selected certificate; the
		// modify-only and ad-hoc paths keep the row certificate-free. The ID is
		// what crosses the queue boundary - never the managed object.
		let certificateID = _options.signingOption == .default ? appCertificate?.objectID : nil

		try await Storage.shared.addSigned(
			uuid: _uuid,
			certificateID: certificateID,
			appName: bundle?.name,
			appIdentifier: bundle?.bundleIdentifier,
			originalAppIdentifier: _originalBundleIdentifier,
			appVersion: bundle?.version,
			appIcon: bundle?.iconFileName,
			appDescription: _appDescription
		)

		Logger.signing.info("[\(self._uuid)] Added to database (original ID: \(self._originalBundleIdentifier ?? "nil"), current ID: \(bundle?.bundleIdentifier ?? "nil"))")

		// The write hands back an ID; the row itself is resolved on the view
		// context. Looking it up by UUID keeps the closure free of managed
		// objects and of a non-Sendable `self`.
		let uuid = _uuid
		signedApp = Storage.shared.app(withUuid: uuid) as? Signed

		_didAddToDatabase = true
	}
	
	private func _directory() async throws -> URL {
		// Documents/VexSign/Signed/\(UUID)
		_fileManager.signed(_uuid)
	}
	
	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
		// A moved-but-unregistered bundle is unreachable from the library, so it would leak forever.
		if !_didAddToDatabase {
			try? _fileManager.removeFileIfNeeded(at: _fileManager.signed(_uuid))
		}
	}
}

extension SigningHandler {
	/// Adds the JIT keys to the entitlements Zsign signs with. Silently skipped for
	/// PPQLess certificates: their distribution profile can't grant `get-task-allow`,
	/// so the keys would only produce an app that fails to launch.
	private func _applyJITEntitlements() throws {
		guard let cert = appCertificate, cert.supportsJIT else {
			SigningLog.shared.info(.localized("Skipping JIT: needs a PPQ certificate."))
			return
		}

		guard let dictionary = _baseEntitlements() else {
			SigningLog.shared.info(.localized("Skipping JIT: no entitlements to extend."))
			return
		}

		let base = ((dictionary as NSDictionary) as? [String: Any]) ?? [:]
		guard EntitlementBuilder.addsJIT(base: base, enableJIT: true, supportsJIT: true) else { return }

		let built = EntitlementBuilder.entitlements(base: base, enableJIT: true, supportsJIT: true)
		let entitlementsURL = _uniqueWorkDir.appendingPathComponent("entitlements.plist")
		try EntitlementBuilder.write(built, to: entitlementsURL)
		_options.appEntitlementsFile = entitlementsURL

		SigningLog.shared.info(.localized("Enabling JIT entitlements"))
	}

	private func _isolateKeychainGroups(for app: URL) async throws {
		guard
			let bundleId = _options.appIdentifier ?? _app.identifier, !bundleId.isEmpty,
			let entitlements = _baseEntitlements(),
			let teamId = _teamIdentifier(from: entitlements)
		else {
			return
		}

		var groups = entitlements["keychain-access-groups"] as? [String] ?? []
		if let executable = Bundle(url: app)?.executableURL {
			groups += MachOEntitlements.keychainAccessGroups(forExecutableAt: executable)
		}

		let isolated = _isolatedGroups(groups, teamId: teamId, bundleId: bundleId)
		guard !isolated.isEmpty else { return }

		entitlements["keychain-access-groups"] = isolated

		let entitlementsURL = _uniqueWorkDir.appendingPathComponent("entitlements.plist")
		let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
		try data.write(to: entitlementsURL)
		_options.appEntitlementsFile = entitlementsURL

		SigningLog.shared.info(.localized("Isolating keychain to %@", arguments: isolated.joined(separator: ", ")))
	}

	private func _baseEntitlements() -> NSMutableDictionary? {
		if let file = _options.appEntitlementsFile, let dict = NSMutableDictionary(contentsOf: file) {
			return dict
		}
		guard
			let cert = appCertificate,
			let entitlements = Storage.shared.getProvisionFileDecoded(for: cert)?.Entitlements
		else {
			return nil
		}
		return NSMutableDictionary(dictionary: entitlements.mapValues { $0.value })
	}

	private func _teamIdentifier(from entitlements: NSDictionary) -> String? {
		if
			let appId = entitlements["application-identifier"] as? String,
			let team = appId.split(separator: ".").first.map(String.init),
			_isTeamIdentifier(team) {
			return team
		}
		for group in entitlements["keychain-access-groups"] as? [String] ?? [] {
			if let team = group.split(separator: ".").first.map(String.init), _isTeamIdentifier(team) {
				return team
			}
		}
		return nil
	}

	// Re-prefix every group with our team so the profile's wildcard authorizes them, give the app a
	// unique default group, and drop Apple-managed groups (e.g. com.apple.token) the cert can't claim.
	private func _isolatedGroups(_ groups: [String], teamId: String, bundleId: String) -> [String] {
		var result: [String] = []
		var seen = Set<String>()

		func append(_ group: String) {
			if seen.insert(group).inserted { result.append(group) }
		}

		append("\(teamId).\(bundleId)")

		for group in groups {
			let expanded = group.replacingOccurrences(of: "*", with: bundleId)
			guard let dot = expanded.firstIndex(of: ".") else { continue }
			guard _isTeamIdentifier(String(expanded[..<dot])) else { continue }

			let suffix = String(expanded[expanded.index(after: dot)...])
			guard !suffix.isEmpty else { continue }
			append("\(teamId).\(suffix)")
		}

		return result
	}

	private func _isTeamIdentifier(_ value: String) -> Bool {
		value.count == 10 && value.allSatisfy { $0.isUppercase && $0.isLetter || $0.isNumber }
	}

	private func _modifyDict(using infoDictionary: NSMutableDictionary, with options: Options, to app: URL) async throws {
		if options.infoPlistChangeCount > 0 {
			SigningLog.shared.info(.localized("Applying custom Info.plist changes"))
		}

		InfoPlistPlan.apply(options, to: infoDictionary)

		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _modifyDict(using infoDictionary: NSMutableDictionary, for image: UIImage, to app: URL) async throws {
		let imageSizes = [
			(width: 120, height: 120, name: "FRIcon60x60@2x.png"),
			(width: 152, height: 152, name: "FRIcon76x76@2x~ipad.png")
		]
		
		for imageSize in imageSizes {
			let resizedImage = image.resize(imageSize.width, imageSize.height)
			let imageData = resizedImage.pngData()
			let fileURL = app.appendingPathComponent(imageSize.name)
			
			try imageData?.write(to: fileURL)
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
		// Only skip the plugin bundle-id rewrite when extensions are being stripped.
		// When extensions are preserved (default), their bundle ids are still rewritten
		// so they remain children of the new app identifier — the original behavior.
		guard !_options.removeAppExtensions else { return }

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
				let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
				if oldValue != newValue {
					infoDict["CFBundleIdentifier"] = newValue
					didChange = true
				}
			}
			
			// WKCompanionAppBundleIdentifier
			if let oldValue = infoDict["WKCompanionAppBundleIdentifier"] as? String {
				let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
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
					let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
					if oldValue != newValue {
						attributes["WKAppBundleIdentifier"] = newValue
						didChange = true
					}
				}

				// NSExtension → NSExtensionFileProviderDocumentGroup
				if
					let oldValue = extensionDict["NSExtensionFileProviderDocumentGroup"] as? String {
					let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
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
	
	/// Logs what the selected profile can do for each nested bundle in the payload.
	private func _auditNestedBundles(at app: URL, certificate: CertificatePair?) {
		// Extensions that were stripped above are no longer in the payload, so there is nothing
		// to audit and nothing to warn about.
		guard !_options.removeAppExtensions else { return }

		let pattern = certificate?.decodedProfile?.Entitlements?["application-identifier"]?.value as? String
		let report = NestedBundleAudit.report(appBundle: app, profilePattern: pattern)
		guard !report.isEmpty else { return }

		for warning in report.warnings {
			SigningLog.shared.warn(warning)
		}
		if let summary = report.summary {
			if report.isClean {
				SigningLog.shared.info(summary)
			} else {
				SigningLog.shared.warn(summary)
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
			try _fileManager.removeFileIfNeeded(at: appex)
			Logger.misc.info("[\(self._uuid)] Removed app extension: \(appex.lastPathComponent)")
		}
	}

	// horrible edge-case
	private func _removeWatchIfNeeded(for app: URL) async throws {
		// A watch app is an app extension; keep it unless extensions are stripped on purpose.
		guard !_options.removeAppExtensions else { return }
		let watchDir = app.appendingPathComponent("Watch")
		guard _fileManager.fileExists(atPath: watchDir.path) else { return }
		
		let contents = try _fileManager.contentsOfDirectory(at: watchDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
		
		for app in contents where app.pathExtension == "app" {
			let infoPlist = app.appendingPathComponent("Info.plist")
			if !_fileManager.fileExists(atPath: infoPlist.path) {
				try? _fileManager.removeItem(at: app)
			}
		}
	}

	private func _removeFiles(for app: URL, from appendingComponent: [String]) async throws {
		let filesToRemove = appendingComponent.map {
			app.appendingPathComponent($0)
		}
		
		for url in filesToRemove {
			try _fileManager.removeFileIfNeeded(at: url)
		}
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
	case signFailed
	
	var errorDescription: String? {
		switch self {
		case .appNotFound: "Unable to locate bundle path."
		case .infoPlistNotFound: "Unable to locate info.plist path."
		case .missingCertifcate: "No certificate was specified."
		case .disinjectFailed: "Removing mach-O load paths failed."
		case .signFailed: "Signing failed."
		}
	}
}
