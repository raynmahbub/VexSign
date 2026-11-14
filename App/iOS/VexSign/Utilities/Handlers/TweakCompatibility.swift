//
//  TweakCompatibility.swift
//  VexSign
//
//  The rules that decide whether a tweak binary or package may be injected into an app
//  that runs inside the iOS sandbox. `TweakAnalyzer` uses them to explain a tweak before
//  signing; `TweakHandler` uses the same rules as a gate, so nothing reaches the app's
//  load commands that the analysis would have warned about.
//
//  Everything here is pure: it works on a `MachOInspector.Inspection`, on strings and on
//  booleans, never on the file system, so each rule can be tested with a few bytes.
//
//  Three facts drive the rules:
//
//  1. A sideloaded app runs as arm64. A library without an arm64 slice — x86_64, armv7,
//     a simulator or macOS build, or arm64e only — is refused by dyld at launch.
//  2. A required load command that names a path outside the app bundle and outside the
//     system (`/Library/…`, `/var/jb/…`, `/usr/local/…`) names a file that does not exist
//     on a device without a jailbreak, and the app does not start.
//  3. Rootful, rootless and roothide packages put their payload in different places and
//     are built against different roots. They are not interchangeable, so the payload is
//     read from the tree the package declares and a package that carries two is refused.
//

import Foundation
import NimbleExtensions

// MARK: - Package layout

/// Where a Debian tweak package expects to be installed.
enum TweakPackageLayout: String, Equatable, Sendable, CaseIterable {
	/// Payload at `/` — `Architecture: iphoneos-arm`.
	case rootful
	/// Payload under `/var/jb` — `Architecture: iphoneos-arm64`.
	case rootless
	/// Payload at `/`, relocated by the bootstrap — `Architecture: iphoneos-arm64e`.
	case roothide
	/// Injectable payload in both the root and the `/var/jb` tree.
	case mixed
	/// Nothing in the package says which it is.
	case unknown

	/// The prefix `/var/jb` has inside a package's data archive.
	static let rootlessPrefix = "var/jb/"

	/// The directories, relative to a payload prefix, that injectable files are read from.
	static let payloadDirectories = [
		"Library/Frameworks/",
		"Library/MobileSubstrate/DynamicLibraries/",
		"Library/Application Support/"
	]

	/// What the control file's `Architecture` field declares, when it is one of the three
	/// values the jailbreak ecosystems use.
	init?(declaredArchitecture: String?) {
		switch declaredArchitecture?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "iphoneos-arm": self = .rootful
		case "iphoneos-arm64": self = .rootless
		case "iphoneos-arm64e": self = .roothide
		default: return nil
		}
	}

	/// The prefixes of the data archive this layout's payload is read from. A mixed package
	/// has none: choosing a tree for it would be a guess.
	var payloadPrefixes: [String] {
		switch self {
		case .rootful, .roothide, .unknown: [""]
		case .rootless: [Self.rootlessPrefix]
		case .mixed: []
		}
	}

	var title: String {
		switch self {
		case .rootful: .localized("Rootful")
		case .rootless: .localized("Rootless")
		case .roothide: .localized("RootHide")
		case .mixed: .localized("Mixed")
		case .unknown: .localized("Unknown")
		}
	}
}

// MARK: - Rules

enum TweakCompatibility {
	// MARK: Findings

	struct Finding: Equatable, Sendable {
		enum Severity: Equatable, Sendable {
			/// The tweak must not be injected: the app would not start, or the input is ambiguous.
			case blocking
			/// Worth telling the user; injection may proceed.
			case advisory
		}

		enum Code: Equatable, Sendable {
			/// Not a Mach-O file, or its header could not be read.
			case notMachO
			/// The load-command list is damaged, so what the binary loads cannot be established.
			case malformedLoadCommands
			/// No arm64 or arm64e slice. Carries the architectures that are present.
			case noDeviceSlice(architectures: [String])
			/// Only an arm64e slice, which an arm64 app process cannot load.
			case arm64eOnly
			/// Built for another platform (macOS, a simulator, tvOS…).
			case wrongPlatform(String)
			/// Still encrypted, so it cannot be re-signed.
			case encrypted
			/// A required library at a path that does not exist inside the sandbox.
			case requiresPathOutsideSandbox(String)
			/// A weak (optional) library at such a path; dyld skips it when it is missing.
			case optionalPathOutsideSandbox(String)
			/// The package has injectable payload in both the root and the `/var/jb` tree.
			case mixedLayout
			/// The control file declares one layout and the payload sits in another.
			case layoutMismatch(declared: TweakPackageLayout, observed: TweakPackageLayout)
			/// A roothide package: its binaries are built against a relocated root.
			case roothidePackage
			/// The tweak calls into a hook runtime and no copy of ElleKit is available to bundle.
			case hookRuntimeUnavailable
			/// The absolute hook-runtime path is still in the library after rewriting it.
			case hookRuntimeNotRedirected(String)
			/// The load command for this library could not be written to the app's executable.
			case loadCommandNotAdded
			/// The package depends on packages that are not being injected with it.
			case unmetDependencies([String])
		}

		let code: Code

		var severity: Severity {
			switch code {
			case .notMachO, .malformedLoadCommands, .noDeviceSlice, .arm64eOnly, .wrongPlatform,
			     .encrypted, .requiresPathOutsideSandbox, .mixedLayout, .hookRuntimeUnavailable,
			     .hookRuntimeNotRedirected, .loadCommandNotAdded:
				.blocking
			case .optionalPathOutsideSandbox, .layoutMismatch, .roothidePackage, .unmetDependencies:
				.advisory
			}
		}

		var isBlocking: Bool { severity == .blocking }

		var message: String {
			switch code {
			case .notMachO:
				return .localized("This file is not a Mach-O library, so it cannot be injected.")
			case .malformedLoadCommands:
				return .localized("This library's load commands are damaged, so what it needs cannot be checked.")
			case .noDeviceSlice(let architectures):
				let list = architectures.isEmpty ? String.localized("none") : architectures.joined(separator: ", ")
				return .localized("This library has no arm64 slice (found: %@), so an iOS app cannot load it.", arguments: list)
			case .arm64eOnly:
				return .localized("This library only has an arm64e slice. Sideloaded apps run as arm64 and cannot load it.")
			case .wrongPlatform(let platform):
				return .localized("This library was built for %@, not iOS.", arguments: platform)
			case .encrypted:
				return .localized("This library is still encrypted and cannot be re-signed.")
			case .requiresPathOutsideSandbox(let path):
				return .localized("This library requires %@, which only exists on a jailbroken device. The app would not start.", arguments: path)
			case .optionalPathOutsideSandbox(let path):
				return .localized("Optionally loads %@, which only exists on a jailbroken device. It is skipped when missing.", arguments: path)
			case .mixedLayout:
				return .localized("This package carries both a rootful and a rootless payload. VexSign will not guess which one to inject; use a package built for one layout.")
			case .layoutMismatch(let declared, let observed):
				return .localized("The package declares a %1$@ layout but its files use a %2$@ layout. The files are what gets injected.", arguments: declared.title, observed.title)
			case .roothidePackage:
				return .localized("This is a RootHide package. Its libraries are built for a relocated jailbreak root and may not work inside an app.")
			case .hookRuntimeUnavailable:
				return .localized("This tweak needs a hook runtime (Substrate or ElleKit), and VexSign's bundled ElleKit could not be found. The app would not start.")
			case .hookRuntimeNotRedirected(let path):
				return .localized("This library still loads %@ after rewriting, so the app would not start.", arguments: path)
			case .loadCommandNotAdded:
				return .localized("The app's executable could not be changed to load this library.")
			case .unmetDependencies(let names):
				return .localized("Depends on %@, which is not part of this injection. Add it as well if the tweak does not work.", arguments: names.joined(separator: ", "))
			}
		}
	}

	/// Thrown by the injection path when a file must not be injected.
	struct Rejected: LocalizedError, Equatable {
		let fileName: String
		let findings: [Finding]

		var errorDescription: String? {
			let reasons = findings.filter(\.isBlocking).map(\.message).joined(separator: " ")
			return String.localized("%1$@ was not injected. %2$@", arguments: fileName, reasons)
		}
	}

	// MARK: Load paths

	enum LoadPathClass: Equatable, Sendable {
		/// `/System/Library/…` and `/usr/lib/…`: provided by iOS.
		case system
		/// `@rpath`, `@executable_path`, `@loader_path`: resolved inside the app bundle.
		case bundleRelative
		/// An absolute path to a Substrate-compatible hook runtime. VexSign rewrites it to the
		/// copy of ElleKit it places in the bundle.
		case hookRuntime
		/// Any other path: it names a file that is not there without a jailbreak.
		case outsideSandbox
	}

	/// The load path the embedded hook runtime answers to.
	static let embeddedHookRuntimePath = "@rpath/CydiaSubstrate.framework/CydiaSubstrate"

	/// File names of hook runtimes whose API the embedded ElleKit framework provides.
	private static let hookRuntimeNames: Set<String> = ["cydiasubstrate", "libsubstrate.dylib", "libellekit.dylib"]

	/// Libraries jailbreaks install into `/usr/lib`, which is otherwise a system directory.
	private static let jailbreakLibraryNames: Set<String> = [
		"libhooker.dylib", "libsubstitute.dylib", "libblackjack.dylib", "libroothide.dylib",
		"librocketbootstrap.dylib", "libapplist.dylib", "libactivator.dylib", "libcolorpicker.dylib"
	]

	static func classify(loadPath: String) -> LoadPathClass {
		if loadPath.hasPrefix("@") { return .bundleRelative }

		let name = (loadPath as NSString).lastPathComponent.lowercased()
		guard loadPath.hasPrefix("/") else { return .outsideSandbox }
		if hookRuntimeNames.contains(name) { return .hookRuntime }
		if loadPath.hasPrefix("/System/Library/") { return .system }
		if loadPath.hasPrefix("/usr/lib/") {
			return jailbreakLibraryNames.contains(name) ? .outsideSandbox : .system
		}
		return .outsideSandbox
	}

	/// The absolute hook-runtime paths a binary loads, in every slice an app could run. The
	/// injection path points each one at `embeddedHookRuntimePath`.
	static func hookRuntimeLoadPaths(in inspection: MachOInspector.Inspection) -> [String] {
		var seen = Set<String>()
		return inspection.deviceNativeSlices
			.flatMap { $0.linkedLibraries + $0.reexportedInstallNames }
			.filter { classify(loadPath: $0) == .hookRuntime && seen.insert($0).inserted }
	}

	// MARK: Binary

	/// Checks one Mach-O library against the facts in the file header. An empty result means
	/// nothing was found that would stop an arm64 app from loading it; it is not a promise
	/// that the tweak works with a particular app.
	static func evaluate(binary inspection: MachOInspector.Inspection) -> [Finding] {
		guard !inspection.slices.isEmpty else { return [Finding(code: .notMachO)] }

		var findings: [Finding] = []
		let damaged = inspection.issues.contains { issue in
			switch issue {
			case .malformedLoadCommands, .invalidStringOffset, .truncatedHeader, .truncatedFatHeader: true
			default: false
			}
		}
		if damaged { findings.append(Finding(code: .malformedLoadCommands)) }

		guard !inspection.deviceNativeSlices.isEmpty else {
			findings.append(Finding(code: .noDeviceSlice(architectures: inspection.architectures.map(\.description))))
			return findings
		}
		guard let slice = inspection.slices.first(where: { $0.architecture == .arm64 }) else {
			findings.append(Finding(code: .arm64eOnly))
			return findings
		}

		// A binary that does not name its platform is an older build; only a named
		// platform other than iOS is evidence against it.
		if let platform = slice.platform, platform != "iOS" {
			findings.append(Finding(code: .wrongPlatform(platform)))
		}
		if slice.isEncrypted { findings.append(Finding(code: .encrypted)) }

		var reported = Set<String>()
		for path in slice.installNames + slice.reexportedInstallNames
		where classify(loadPath: path) == .outsideSandbox && reported.insert(path).inserted {
			findings.append(Finding(code: .requiresPathOutsideSandbox(path)))
		}
		for path in slice.weakInstallNames
		where classify(loadPath: path) == .outsideSandbox && reported.insert(path).inserted {
			findings.append(Finding(code: .optionalPathOutsideSandbox(path)))
		}
		return findings
	}

	// MARK: Package layout

	struct LayoutResolution: Equatable, Sendable {
		let layout: TweakPackageLayout
		let findings: [Finding]

		var isBlocked: Bool { findings.contains(where: \.isBlocking) }
	}

	/// Decides which tree of a package is its payload.
	///
	/// The files decide, because the files are what is injected; the control file's
	/// `Architecture` only separates rootful from roothide, which use the same paths, and is
	/// reported when it disagrees with the files.
	static func resolveLayout(
		declaredArchitecture: String?,
		hasRootPayload: Bool,
		hasRootlessPayload: Bool
	) -> LayoutResolution {
		let declared = TweakPackageLayout(declaredArchitecture: declaredArchitecture)

		switch (hasRootPayload, hasRootlessPayload) {
		case (true, true):
			return LayoutResolution(layout: .mixed, findings: [Finding(code: .mixedLayout)])
		case (false, true):
			var findings: [Finding] = []
			if let declared, declared != .rootless {
				findings.append(Finding(code: .layoutMismatch(declared: declared, observed: .rootless)))
			}
			return LayoutResolution(layout: .rootless, findings: findings)
		case (true, false):
			if declared == .roothide {
				return LayoutResolution(layout: .roothide, findings: [Finding(code: .roothidePackage)])
			}
			var findings: [Finding] = []
			if declared == .rootless {
				findings.append(Finding(code: .layoutMismatch(declared: .rootless, observed: .rootful)))
			}
			return LayoutResolution(layout: .rootful, findings: findings)
		case (false, false):
			// No payload where injection reads from: the declaration is all there is.
			return LayoutResolution(layout: declared ?? .unknown, findings: [])
		}
	}

	/// Which trees hold injectable payload, from paths relative to the root of a package's
	/// data archive (a leading `/` or `./` is ignored).
	static func payloadPresence(inRelativePaths paths: [String]) -> (root: Bool, rootless: Bool) {
		var root = false
		var rootless = false
		for raw in paths {
			var path = Substring(raw)
			while true {
				if path.hasPrefix("/") {
					path = path.dropFirst(1)
				} else if path.hasPrefix("./") {
					path = path.dropFirst(2)
				} else {
					break
				}
			}
			if path.hasPrefix(TweakPackageLayout.rootlessPrefix) {
				let inner = path.dropFirst(TweakPackageLayout.rootlessPrefix.count)
				if TweakPackageLayout.payloadDirectories.contains(where: { inner.hasPrefix($0) }) { rootless = true }
			} else if TweakPackageLayout.payloadDirectories.contains(where: { path.hasPrefix($0) }) {
				root = true
			}
		}
		return (root, rootless)
	}
}

// MARK: - Package dependencies

extension TweakCompatibility {
	/// Package names that describe the jailbreak itself or the hook runtime VexSign bundles.
	/// A dependency on one of these is satisfied, or meaningless, inside a sideloaded app.
	private static let providedPackages: Set<String> = [
		"mobilesubstrate", "com.saurik.substrate", "com.ex.substitute", "org.coolstar.libhooker",
		"ellekit", "firmware", "cy+cpu.arm64", "cy+cpu.arm64e", "cy+model.iphone", "cy+model.ipad",
		"cydia", "apt", "dpkg", "base", "bash", "coreutils", "preferenceloader",
	]

	/// The package names in a control file's `Depends` field.
	///
	/// Version constraints and architecture qualifiers are dropped. Of a set of alternatives
	/// (`a | b`) every name is returned as one group, since any one of them satisfies it.
	static func dependencyGroups(fromDependsField field: String?) -> [[String]] {
		guard let field else { return [] }
		return field.split(separator: ",").compactMap { clause -> [String]? in
			let names = clause.split(separator: "|").compactMap { alternative -> String? in
				var name = Substring(alternative)
				if let paren = name.firstIndex(of: "(") { name = name[..<paren] }
				if let colon = name.firstIndex(of: ":") { name = name[..<colon] }
				let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
				return trimmed.isEmpty ? nil : trimmed
			}
			return names.isEmpty ? nil : names
		}
	}

	/// Dependencies that nothing in this injection satisfies.
	///
	/// - Parameters:
	///   - field: the `Depends` value from the control file.
	///   - available: identifiers of the other packages injected in the same run.
	/// - Returns: one name per unmet group (its first alternative), in the order declared.
	static func unmetDependencies(dependsField field: String?, available: Set<String> = []) -> [String] {
		let known = providedPackages.union(available.map { $0.lowercased() })
		var unmet: [String] = []
		for group in dependencyGroups(fromDependsField: field) where !group.contains(where: known.contains) {
			if let first = group.first, !unmet.contains(first) { unmet.append(first) }
		}
		return unmet
	}
}
