//
//  DylibHandler.swift
//  vexsign
//
//  Created by VexSign Contributors on 8/17/24.
//  Copyright (c) 2026 VexSign Team
//

import Foundation
import ZsignSwift
import OSLog
import NimbleExtensions

class TweakHandler {
	private let _fileManager = FileManager.default

	private let _app: URL
	private var _options: Options
	/// Legacy injection files + ellekit when needed.
	private var _urls: [URL]

	init(
		app: URL,
		options: Options = OptionsManager.shared.options
	) {
		self._app = app
		self._options = options
		self._urls = options.injectionFiles
	}

	/// Enabled tweak specs for this sign.
	private var _enabledSpecs: [TweakInjectionSpec] {
		(_options.tweakInjections ?? []).filter { $0.enabled }
	}

	private var _hasAnyInjection: Bool {
		!_options.injectionFiles.isEmpty || !_enabledSpecs.isEmpty
	}

	/// Bundled document picker fix
	private var _filePickerFixURL: URL? {
		guard _options.fixFilePicker else { return nil }
		guard let url = Bundle.main.url(forResource: "FilePickerFix", withExtension: "dylib") else {
			SigningLog.shared.error(.localized("File picker fix is unavailable"))
			return nil
		}
		return url
	}

	/// `Frameworks/` can be absent from apps, so the parent has to exist before the move.
	private func _place(_ url: URL, at destination: URL) throws {
		try _fileManager.createDirectoryIfNeeded(at: destination.deletingLastPathComponent())
		// The move silently drops a same-named file.
		if _fileManager.fileExists(atPath: destination.path) {
			SigningLog.shared.error(.localized("Kept the existing %@ — another tweak ships a file with that name", arguments: destination.lastPathComponent))
		}
		try _fileManager.moveFileIfNeeded(from: url, to: destination)
	}

	/// Suffixes `-2`, `-3`… so two tweaks can ship the same dylib name.
	private func _uniqueDylibDestination(_ destination: URL) -> URL {
		guard _fileManager.fileExists(atPath: destination.path) else { return destination }

		let directory = destination.deletingLastPathComponent()
		let base = destination.deletingPathExtension().lastPathComponent
		let ext = destination.pathExtension

		var index = 2
		var candidate = destination
		repeat {
			candidate = directory.appendingPathComponent("\(base)-\(index).\(ext)")
			index += 1
		} while _fileManager.fileExists(atPath: candidate.path)

		SigningLog.shared.info(.localized("Renamed %1$@ to %2$@ — that name was already taken", arguments: destination.lastPathComponent, candidate.lastPathComponent))
		return candidate
	}

	private func _findEllekitURL() -> URL? {
		if let url = Bundle.main.url(forResource: "ellekit", withExtension: "deb"), _fileManager.fileExists(atPath: url.path) {
			return url
		}
		if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("ellekit.deb"), _fileManager.fileExists(atPath: resourceURL.path) {
			return resourceURL
		}
		let bundleResource = Bundle.main.bundleURL.appendingPathComponent("Resources/ellekit.deb")
		if _fileManager.fileExists(atPath: bundleResource.path) {
			return bundleResource
		}
		if let docURL = _fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("ellekit.deb"), _fileManager.fileExists(atPath: docURL.path) {
			return docURL
		}
		return nil
	}

	private func _requiresSubstrateHooking() async -> Bool {
		let allTweakURLs = _options.injectionFiles + _enabledSpecs.flatMap { $0.files.filter(\.enabled).map(\.fileURL) }
		for url in allTweakURLs {
			let analysis = await TweakAnalyzer.analyze(
				fileURL: url,
				type: TweakFileType(fileExtension: url.pathExtension),
				appURL: _app
			)
			if analysis.needsSubstrate {
				return true
			}
		}
		return false
	}

	private func _checkEllekit() async throws {
		let frameworksPath = _app.appendingPathComponent("Frameworks").appendingPathComponent("CydiaSubstrate.framework")
		let ellekitDylibPath = _app.appendingPathComponent("Frameworks").appendingPathComponent("ellekit.dylib")
		let hasExistingHookFramework = _fileManager.fileExists(atPath: frameworksPath.path) || _fileManager.fileExists(atPath: ellekitDylibPath.path)

		func addEllekit(reason: String, required: Bool = false) async throws {
			if let ellekitURL = _findEllekitURL() {
				SigningLog.shared.info(.localized("Auto-injecting ElleKit (%@)", arguments: reason), category: "inject")
				self._urls.insert(ellekitURL, at: 0)
			} else if required {
				// The tweak links the hook runtime. Without it dyld cannot resolve the library
				// and the app stops at launch, so this is a refusal, not a warning.
				throw TweakCompatibility.Rejected(
					fileName: "ElleKit",
					findings: [TweakCompatibility.Finding(code: .hookRuntimeUnavailable)]
				)
			} else {
				SigningLog.shared.warn(.localized("Tweak requires Substrate/Substitute, but ellekit.deb was not found"), category: "inject")
				Logger.misc.info("ellekit.deb not found in the app bundle or documents")
			}

			try _fileManager.createDirectoryIfNeeded(at: _app.appendingPathComponent("Frameworks"))
		}

		if hasExistingHookFramework {
			if _options.experiment_replaceSubstrateWithEllekit {
				SigningLog.shared.info(.localized("Replacing Substrate with ElleKit"))
				try _fileManager.removeFileIfNeeded(at: frameworksPath)
				try await addEllekit(reason: "replacement requested")
			} else {
				return
			}
		} else {
			let needsSubstrate = await _requiresSubstrateHooking()
			if needsSubstrate {
				try await addEllekit(reason: "detected Substrate/Substitute dependency", required: true)
			} else if _hasAnyInjection {
				try await addEllekit(reason: "bundle hook runtime")
			}
		}
	}

	public func getInputFiles() async throws {
		Logger.misc.info("Attempting to inject")

		let filePickerFix = _filePickerFixURL

		if !_options.experiment_replaceSubstrateWithEllekit {
			guard _hasAnyInjection || filePickerFix != nil else { return }
		}

		// A one-shot file that is gone cannot be injected. Stop before anything in the bundle is
		// changed, and name the file: this used to surface halfway through the job as a Cocoa
		// "no such file", which told the user nothing about which input to add again.
		let oneShotFiles = _options.injectionFiles
		let unavailable = OneShotTweakFiles.unavailable(oneShotFiles, fileManager: _fileManager)
		guard unavailable.isEmpty else {
			throw OneShotTweakFiles.Unavailable(names: OneShotTweakFiles.names(unavailable))
		}

		try await _checkEllekit()

		let baseTmpDir = _fileManager.uniqueTemporaryDirectory("VexSignTweak")
		try _fileManager.createDirectoryIfNeeded(at: baseTmpDir)
		// Everything this run needs has been moved or copied into the bundle by the time it
		// returns, on success and on failure alike, so the staging directory goes with it.
		defer {
			do {
				try _fileManager.removeFileIfNeeded(at: baseTmpDir)
			} catch {
				Logger.misc.warning("Could not remove the tweak staging directory: \(error.localizedDescription)")
			}
		}

		// The job below moves what it is handed into the bundle. Handing it the files the user
		// staged consumed them: the next attempt in the same sheet, and every later run that
		// reused the saved settings, then failed here. It works on its own copies instead, so the
		// staged files stay valid until the sheet that owns them discards them.
		let oneShotCopies = try OneShotTweakFiles.stage(oneShotFiles, into: baseTmpDir, fileManager: _fileManager)
		_urls = _urls.filter { !oneShotFiles.contains($0) } + oneShotCopies

		if let filePickerFix {
			let staged = baseTmpDir.appendingPathComponent(filePickerFix.lastPathComponent)
			try _fileManager.copyItem(at: filePickerFix, to: staged)
			_urls.append(staged)
		}

		// Legacy job: injectionFiles + ellekit, extensions only when injectIntoExtensions.
		if !_urls.isEmpty {
			let names = try await _runJob(
				urls: _urls,
				baseTmpDir: baseTmpDir,
				path: _options.injectPath,
				folder: _options.injectFolder
			)
			_injectIntoTargets(
				dylibNames: names,
				targeting: _options.injectIntoExtensions ? .all : .mainOnly,
				path: _options.injectPath,
				folder: _options.injectFolder
			)
			for name in names {
				SigningLog.shared.info(.localized("Injected %@", arguments: name), category: "inject")
			}
		}

		// Managed specs: each file carries its own config + targeting, processed
		// independently so one bad file doesn't abort the sign.
		for spec in _enabledSpecs {
			for file in spec.files where file.enabled {
				do {
					try await _processSpecFile(file, spec: spec, baseTmpDir: baseTmpDir)
				} catch {
					SigningLog.shared.error(.localized("Failed to inject %@", arguments: file.fileName), category: "inject")
					SigningLog.shared.info(">>> \(error.localizedDescription)", category: "inject")
				}
			}
		}
	}

	/// Stages one tweak file, then places (.appex) or injects it.
	private func _processSpecFile(_ file: TweakInjectionFile, spec: TweakInjectionSpec, baseTmpDir: URL) async throws {
		let path = file.config.resolvedPath(global: _options.injectPath)
		let folder = file.config.resolvedFolder(global: _options.injectFolder)

		// Copy into temp first so the persistent library file isn't moved away.
		let staged = baseTmpDir.appendingPathComponent(UUID().uuidString)
		try _fileManager.createDirectoryIfNeeded(at: staged)
		let stagedFile = staged.appendingPathComponent(file.fileURL.lastPathComponent)
		try _fileManager.copyItem(at: file.fileURL, to: stagedFile)

		// App extensions are placed in PlugIns/ and signed with the app, not injected.
		if file.fileType == .appex || stagedFile.pathExtension.lowercased() == "appex" {
			try _handleAppex(at: stagedFile)
			SigningLog.shared.info(.localized("Placed extension %@", arguments: file.fileName), category: "inject")
			return
		}

		let names = try await _runJob(urls: [stagedFile], baseTmpDir: baseTmpDir, path: path, folder: folder)
		_injectIntoTargets(dylibNames: names, targeting: file.config.targeting, path: path, folder: folder)
		SigningLog.shared.info(.localized("Injected %@", arguments: file.fileName), category: "inject")
	}

	// MARK: - App extensions (.appex)

	/// Drops an appex into PlugIns/ and rewrites its bundle id under the host app id so iOS
	/// accepts it and zsign signs it with the bundle (same path as an in-IPA appex).
	private func _handleAppex(at url: URL) throws {
		let pluginsDir = _app.appendingPathComponent("PlugIns")
		try _fileManager.createDirectoryIfNeeded(at: pluginsDir)

		var destination = pluginsDir.appendingPathComponent(url.lastPathComponent)
		// Avoid clobbering an extension the app already ships with that exact name.
		if _fileManager.fileExists(atPath: destination.path) {
			let base = url.deletingPathExtension().lastPathComponent
			destination = pluginsDir.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).appex")
		}
		try _fileManager.moveFileIfNeeded(from: url, to: destination)
		_rewriteAppexBundleId(at: destination)
	}

	/// Sets the appex `CFBundleIdentifier` to `<hostId>.<suffix>` (required parent/child);
	/// host id is the app's final Info.plist id, already written by `SigningHandler`.
	private func _rewriteAppexBundleId(at appex: URL) {
		let infoURL = appex.appendingPathComponent("Info.plist")
		guard
			let info = NSDictionary(contentsOf: infoURL)?.mutableCopy() as? NSMutableDictionary
		else { return }

		let hostId = _options.effectiveAppIdentifier
			?? (NSDictionary(contentsOf: _app.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String)
		guard let hostId, !hostId.isEmpty else { return }

		let rawSuffix = appex.deletingPathExtension().lastPathComponent
		let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
		var suffix = String(rawSuffix.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
		while suffix.contains("--") { suffix = suffix.replacingOccurrences(of: "--", with: "-") }
		suffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
		if suffix.isEmpty { suffix = "extension" }

		info["CFBundleIdentifier"] = "\(hostId).\(suffix)"
		info.write(to: infoURL, atomically: true)
		Logger.misc.info("Placed app extension \(appex.lastPathComponent) as \(hostId).\(suffix)")
	}

	// MARK: - Job pipeline

	/// Injects each input (dylib/deb) into the MAIN binary; returns injected dylib names for targeting.
	private func _runJob(
		urls: [URL],
		baseTmpDir: URL,
		path: Options.InjectPath,
		folder: Options.InjectFolder
	) async throws -> [String] {
		var collected: [String] = []
		var payloads: [DebPayload] = []

		// Everything is checked before anything is placed: a refusal must leave the bundle as
		// it was, not half-injected. Packages are unpacked first so their contents are part of
		// the same check.
		for url in urls where url.pathExtension.lowercased() == "deb" {
			payloads.append(contentsOf: try await _handleDeb(at: url, baseTmpDir: baseTmpDir))
		}
		// Dependencies between packages are reported, not enforced: whether a missing library
		// matters is only known at run time, and many tweaks list packages they never load.
		let packaged = Set(payloads.compactMap(\.package))
		for payload in payloads {
			let unmet = TweakCompatibility.unmetDependencies(dependsField: payload.depends, available: packaged)
			guard !unmet.isEmpty else { continue }
			let finding = TweakCompatibility.Finding(code: .unmetDependencies(unmet))
			SigningLog.shared.info("\(payload.fileName): \(finding.message)", category: "inject")
		}
		let extracted = try await _collectFromDirectories(payloads)
		for url in urls + extracted {
			try _requireInjectable(url)
		}

		for url in urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				if let name = try await _handleDylib(at: url, path: path, folder: folder) {
					collected.append(name)
				}
			case "deb":
				// Unpacked above; its contents are injected after the direct inputs.
				break
			case "framework":
				// Drop into Frameworks/, add load command; return load name for targeting.
				let destinationURL = _app.appendingPathComponent("Frameworks").appendingPathComponent(url.lastPathComponent)
				try _place(url, at: destinationURL)
				try await _handleDylib(framework: destinationURL)
				if let fexe = Bundle(url: destinationURL)?.executableURL?.lastPathComponent {
					collected.append("\(destinationURL.lastPathComponent)/\(fexe)")
				}
			case "bundle":
				// Resource bundle — copy into the app root, nothing to inject.
				let destinationURL = _app.appendingPathComponent(url.lastPathComponent)
				try _fileManager.moveFileIfNeeded(from: url, to: destinationURL)
			default:
				Logger.misc.warning("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}

		if !extracted.isEmpty {
			collected.append(contentsOf: try await _handleExtractedContents(at: extracted, path: path, folder: folder))
		}

		return collected
	}

	// MARK: - Compatibility gate

	/// One unpacked package: the root of its data archive and the tree its payload is in.
	private struct DebPayload {
		let root: URL
		let layout: TweakPackageLayout
		/// The `.deb`'s file name, for messages.
		let fileName: String
		/// `Package` and `Depends` from the control file, when it had them.
		let package: String?
		let depends: String?
	}

	/// Refuses a library or framework that an arm64 app in the sandbox could not load.
	///
	/// The rules are `TweakCompatibility`'s, the same ones the tweak's info screen shows, so
	/// a file is never injected with a problem the screen would have named. Other inputs
	/// (packages, resource bundles) carry no code of their own and pass.
	private func _requireInjectable(_ url: URL) throws {
		let binary: URL
		switch url.pathExtension.lowercased() {
		case "dylib":
			binary = url
		case "framework":
			guard let executable = Bundle(url: url)?.executableURL else {
				throw TweakCompatibility.Rejected(
					fileName: url.lastPathComponent,
					findings: [TweakCompatibility.Finding(code: .notMachO)]
				)
			}
			binary = executable
		default:
			return
		}

		let findings = TweakCompatibility.evaluate(binary: MachOInspector.inspect(fileAt: binary))
		for finding in findings where !finding.isBlocking {
			SigningLog.shared.info("\(url.lastPathComponent): \(finding.message)", category: "inject")
		}
		guard !findings.contains(where: \.isBlocking) else {
			throw TweakCompatibility.Rejected(fileName: url.lastPathComponent, findings: findings)
		}
	}

	/// Points every absolute hook-runtime path a library loads at the ElleKit copy inside the
	/// bundle. Rootful, rootless and `libsubstrate`/`libellekit` spellings all name a file that
	/// is absent without a jailbreak; left alone, any of them stops the app at launch.
	///
	/// The result is read back from the file rather than taken from the rewrite's return
	/// value: what matters is whether an absolute path is still there.
	private func _redirectHookRuntime(inBinaryAt binary: URL) throws {
		let paths = TweakCompatibility.hookRuntimeLoadPaths(in: MachOInspector.inspect(fileAt: binary))
		guard !paths.isEmpty else { return }
		for old in paths {
			_ = Zsign.changeDylibPath(
				appExecutable: binary.path,
				for: old,
				with: TweakCompatibility.embeddedHookRuntimePath
			)
		}
		let remaining = TweakCompatibility.hookRuntimeLoadPaths(in: MachOInspector.inspect(fileAt: binary))
		if let left = remaining.first {
			throw TweakCompatibility.Rejected(
				fileName: binary.lastPathComponent,
				findings: [TweakCompatibility.Finding(code: .hookRuntimeNotRedirected(left))]
			)
		}
	}

	/// Adds the load command for an injected library to the app's own executable. A failure
	/// here would otherwise produce a signed app that silently lacks the tweak.
	private func _addLoadCommand(_ loadPath: String, toExecutableAt executable: URL, for fileName: String) throws {
		guard Zsign.injectDyLib(appExecutable: executable.path, with: loadPath) else {
			throw TweakCompatibility.Rejected(
				fileName: fileName,
				findings: [TweakCompatibility.Finding(code: .loadCommandNotAdded)]
			)
		}
	}

	// MARK: - Inject (main binary)

	// Inject imported dylib into the main binary; returns injected name.
	@discardableResult
	private func _handleDylib(
		at url: URL,
		path: Options.InjectPath,
		folder: Options.InjectFolder
	) async throws -> String? {
		var destinationURL = _app
		var injectFolder = folder

		// check for "/Frameworks/", then append the destinationUrl
		if folder == .frameworks {
			destinationURL = destinationURL.appendingPathComponent("Frameworks")
		}

		// We check for "@rpath" and "/Frameworks/", if they're both enabled force
		// the inject folder to be root "/" instead, as the @rpath is already in
		// frameworks
		if path == .rpath && folder == .frameworks {
			injectFolder = .root
		}

		destinationURL = _uniqueDylibDestination(destinationURL.appendingPathComponent(url.lastPathComponent))

		try _place(url, at: destinationURL)

		guard let appexe = Bundle(url: _app)?.executableURL else {
			return nil
		}

		// change paths because some tweaks hardlink, which is not ideal.
		try _redirectHookRuntime(inBinaryAt: destinationURL)
		// inject if there's a valid app main executable
		try _addLoadCommand(
			"\(path.rawValue)\(injectFolder.rawValue)\(destinationURL.lastPathComponent)",
			toExecutableAt: appexe,
			for: destinationURL.lastPathComponent
		)

		return destinationURL.lastPathComponent
	}

	// Inject imported framework dir (main binary only).
	private func _handleDylib(framework: URL) async throws {
		guard
			let fexe = Bundle(url: framework)?.executableURL,
			let appexe = Bundle(url: _app)?.executableURL
		else {
			return
		}

		try _redirectHookRuntime(inBinaryAt: fexe)
		try _addLoadCommand(
			"@executable_path/Frameworks/\(framework.lastPathComponent)/\(fexe.lastPathComponent)",
			toExecutableAt: appexe,
			for: framework.lastPathComponent
		)
	}

	// Handle extracted deb contents (dylibs, frameworks, bundles). Returns injected dylib names.
	private func _handleExtractedContents(
		at urls: [URL],
		path: Options.InjectPath,
		folder: Options.InjectFolder
	) async throws -> [String] {
		var collected: [String] = []
		for url in urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				if let name = try await _handleDylib(at: url, path: path, folder: folder) {
					collected.append(name)
				}
			case "framework":
				let destinationURL = _app.appendingPathComponent("Frameworks").appendingPathComponent(url.lastPathComponent)
				try _place(url, at: destinationURL)
				try await _handleDylib(framework: destinationURL)
			case "bundle":
				let destinationURL = _app.appendingPathComponent(url.lastPathComponent)
				try _fileManager.moveFileIfNeeded(from: url, to: destinationURL)
			default:
				Logger.misc.warning("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}
		return collected
	}

	// MARK: - deb extraction

	// Extract imported deb file, returns the extracted data trees and the layout each one uses.
	private func _handleDeb(at url: URL, baseTmpDir: URL) async throws -> [DebPayload] {
		let uniqueSubDir = baseTmpDir.appendingPathComponent(UUID().uuidString)
		try _fileManager.createDirectoryIfNeeded(at: uniqueSubDir)

		var directories: [URL] = []
		var control: [String: String] = [:]

		let handler = try AR(with: url)
		let arFiles = try await handler.extract()

		for arFile in arFiles {
			let outputPath = uniqueSubDir.appendingPathComponent(arFile.name)
			try arFile.content.write(to: outputPath)

			if ["data.tar.lzma", "data.tar.gz", "data.tar.xz", "data.tar.bz2"].contains(arFile.name) {
				var fileToProcess = outputPath
				try extractFile(at: &fileToProcess)
				try extractFile(at: &fileToProcess)
				directories.append(fileToProcess)
			} else if arFile.name.hasPrefix("control.tar") {
				control = TweakAnalyzer.readControl(fromTar: outputPath) ?? [:]
			}
		}

		// Rootful, rootless and roothide packages are not interchangeable. The tree the
		// package actually uses is the one read; a package with payload in both is refused
		// rather than injected twice.
		return try directories.map { root in
			let resolution = TweakCompatibility.resolveLayout(
				declaredArchitecture: control["architecture"],
				hasRootPayload: _hasPayload(in: root, prefix: ""),
				hasRootlessPayload: _hasPayload(in: root, prefix: TweakPackageLayout.rootlessPrefix)
			)
			for finding in resolution.findings where !finding.isBlocking {
				SigningLog.shared.info("\(url.lastPathComponent): \(finding.message)", category: "inject")
			}
			guard !resolution.isBlocked else {
				throw TweakCompatibility.Rejected(fileName: url.lastPathComponent, findings: resolution.findings)
			}
			return DebPayload(
				root: root,
				layout: resolution.layout,
				fileName: url.lastPathComponent,
				package: control["package"],
				depends: control["depends"]
			)
		}
	}

	/// Whether a data tree has anything in the directories injection reads from.
	private func _hasPayload(in root: URL, prefix: String) -> Bool {
		TweakPackageLayout.payloadDirectories.contains { directory in
			let url = root.appendingPathComponent(prefix + directory)
			let names = (try? _fileManager.contentsOfDirectory(atPath: url.path)) ?? [] // try? ok: a missing or unreadable directory holds no payload
			return names.contains { !$0.hasPrefix(".") }
		}
	}

	// Read extracted deb directories, locate all necessary contents to copy over to the .app
	private func _collectFromDirectories(_ payloads: [DebPayload]) async throws -> [URL] {
		enum DirectoryType: CaseIterable {
			case frameworks
			case dynamicLibraries
			case applicationSupport

			var path: String {
				switch self {
				case .frameworks: "Library/Frameworks/"
				case .dynamicLibraries: "Library/MobileSubstrate/DynamicLibraries/"
				case .applicationSupport: "Library/Application Support/"
				}
			}
		}

		var result: [URL] = []

		for payload in payloads {
			// Only the tree this package's layout uses — see `TweakPackageLayout.payloadPrefixes`.
			for prefix in payload.layout.payloadPrefixes {
				for directoryType in DirectoryType.allCases {
					let directoryURL = payload.root.appendingPathComponent(prefix + directoryType.path)

					guard _fileManager.fileExists(atPath: directoryURL.path) else {
						continue
					}

					switch directoryType {
					case .dynamicLibraries:
						result.append(contentsOf: try await _locateDylibFiles(in: directoryURL))
					case .frameworks:
						result.append(contentsOf: try await _locateFrameworkDirectories(in: directoryURL))
					case .applicationSupport:
						result.append(contentsOf: try await _searchForBundles(in: directoryURL))
					}
				}
			}
		}

		return result
	}

	// MARK: - Extension targeting

	// Discovers all .appex bundles in the app's PlugIns and Extensions directories
	private func _discoverAppExtensions() -> [URL] {
		AppExtensionEnumerator.appexBundles(in: _app)
	}

	/// Injects the given dylib names into the targeted extensions.
	private func _injectIntoTargets(
		dylibNames: [String],
		targeting: ExtensionTargeting,
		path: Options.InjectPath,
		folder: Options.InjectFolder
	) {
		guard !dylibNames.isEmpty else { return }

		let targets: [URL]
		switch targeting {
		case .mainOnly:
			return
		case .all:
			targets = _discoverAppExtensions()
		case .selected(let names):
			targets = _discoverAppExtensions().filter { names.contains($0.lastPathComponent) }
		}

		guard !targets.isEmpty else {
			Logger.misc.info("No matching app extensions found for injection")
			return
		}

		Logger.misc.info("Injecting into \(targets.count) app extension(s)")

		for extensionURL in targets {
			for dylibName in dylibNames {
				_injectIntoExtension(extensionURL: extensionURL, dylibName: dylibName, path: path, folder: folder)
			}
		}
	}

	// Injects a dylib into an extension's executable
	private func _injectIntoExtension(
		extensionURL: URL,
		dylibName: String,
		path: Options.InjectPath,
		folder: Options.InjectFolder
	) {
		guard
			let extensionBundle = Bundle(url: extensionURL),
			let extensionExecutable = extensionBundle.executableURL
		else {
			Logger.misc.warning("Skipping \(extensionURL.lastPathComponent): couldn't read bundle")
			SigningLog.shared.error(.localized("%1$@ was not added to the extension %2$@", arguments: dylibName, extensionURL.lastPathComponent))
			return
		}

		// Framework load-names always resolve inside Frameworks/, regardless of inject folder.
		let isFramework = dylibName.contains(".framework/")

		var injectFolder = folder
		if path == .rpath && folder == .frameworks {
			injectFolder = .root
		}

		let injectPath: String
		if path == .rpath {
			injectPath = "@rpath/\(dylibName)"
		} else if isFramework || injectFolder == .frameworks {
			injectPath = "@executable_path/../../Frameworks/\(dylibName)"
		} else {
			injectPath = "@executable_path/../../\(dylibName)"
		}

		let success = Zsign.injectDyLib(
			appExecutable: extensionExecutable.path,
			with: injectPath
		)

		if success {
			Logger.misc.info("Injected \(dylibName) into extension: \(extensionURL.lastPathComponent)")
		} else {
			Logger.misc.warning("Failed to inject into extension: \(extensionURL.lastPathComponent)")
			// The app itself is still signed with the tweak; say which extension is without it
			// where the user reads the run, not only in the system log.
			SigningLog.shared.error(.localized("%1$@ was not added to the extension %2$@", arguments: dylibName, extensionURL.lastPathComponent))
		}
	}
}

// MARK: - Find correct files in debs
extension TweakHandler {
	private func _searchForBundles(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let allFiles = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let bundleDirectories = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "bundle" && url.hasDirectoryPath && !isSymlink
		}

		var result: [URL] = bundleDirectories

		let directoriesToSearch = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.hasDirectoryPath && !bundleDirectories.contains(url) && !isSymlink
		}

		for dirURL in directoriesToSearch {
			result.append(contentsOf: try await _searchForBundles(in: dirURL))
		}

		return result
	}

	private func _locateDylibFiles(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])

		return files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "dylib" && !isSymlink
		}
	}

	private func _locateFrameworkDirectories(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		return files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "framework" && url.hasDirectoryPath && !isSymlink
		}
	}
}

enum TweakHandlerError: Error {
	case unsupportedFileExtension(String)
	case decompressionFailed(String)
	case missingFile(String)
	case noAccess
}
