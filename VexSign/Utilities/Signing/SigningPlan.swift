//
//  SigningPlan.swift
//  VexSign
//
//  What is inside an app bundle and in which order it has to be signed.
//
//  The bundled engine walks the tree itself, so this plan does not drive zsign. What it does is
//  make the expectation explicit: which nested bundles exist, what each one is, whether it
//  carries an identifier and an executable, and the order a correct signature has to cover them
//  in. That expectation was previously implied by three separate walks — `NestedBundleAudit`
//  for profile coverage, `SignatureVerifier` for post-sign checks, `AppExtensionEnumerator` for
//  the UI — each with its own idea of what counts as a nested bundle.
//
//  Discovery is deliberately narrow. Only the locations iOS actually loads executable code from
//  are scanned, and a directory only counts when it has the extension for its kind. A resource
//  folder called `Something.appex` inside a theme directory is not an extension, and walking
//  every directory looking for bundles would eventually find one and try to sign it.
//
//  Pure and synchronous: no singletons, no Core Data, no engine. That is what makes the order
//  and the validation testable against a temporary directory.
//

import Foundation
import NimbleExtensions

// MARK: - Plan

struct SigningPlan: Equatable {
	/// The kinds of nested code iOS expects to find inside an app.
	enum Kind: String, CaseIterable {
		/// `PlugIns/*.appex` — widgets, share sheets, keyboards.
		case appExtension
		/// `Watch/*.app` — a watchOS companion application.
		case watchApp
		/// An extension inside a watch app.
		case watchExtension
		/// `Frameworks/*.framework`.
		case framework
		/// A loose `*.dylib`, normally injected.
		case dylib
		/// `PlugIns/*.appex` that lives under an extension host other than the app itself.
		case plugin
		/// A nested `.app` that is not a watch app (helper applications, including guest hosts).
		case embeddedApp

		/// Whether iOS requires a provisioning profile for this kind. Frameworks and dylibs
		/// are signed without one, which is why `NestedBundleAudit` deliberately skips them.
		var requiresProfile: Bool {
			switch self {
			case .appExtension, .watchApp, .watchExtension, .plugin, .embeddedApp:
				true
			case .framework, .dylib:
				false
			}
		}
	}

	struct Component: Equatable, Identifiable {
		/// Path relative to the app bundle, e.g. `PlugIns/Widget.appex`.
		let path: String
		let kind: Kind
		let identifier: String?
		let hasExecutable: Bool

		var id: String { path }

		/// How deeply nested the component is; deeper components must be signed first.
		var depth: Int { path.split(separator: "/").count }

		var displayName: String { (path as NSString).lastPathComponent }

		/// A nested bundle that iOS will refuse to load: no identifier, or no executable.
		var isStructurallyComplete: Bool {
			identifier?.isEmpty == false && hasExecutable
		}
	}

	/// Every component, deepest first. Ties are broken by path so two runs over the same bundle
	/// produce the same order on any filesystem.
	let components: [Component]

	var isEmpty: Bool { components.isEmpty }

	/// The components that must carry their own profile, in signing order.
	var profileBoundComponents: [Component] { components.filter { $0.kind.requiresProfile } }

	static func make(appBundle: URL) -> SigningPlan {
		SigningPlan(components: _discover(in: appBundle))
	}

	/// Problems that make the bundle unsignable before the engine is ever invoked.
	///
	/// Only profile-bound kinds are treated as blocking: a framework without a `CFBundleExecutable`
	/// is already reported by the post-sign verifier, and blocking a run on a third-party
	/// framework's metadata would refuse bundles that install fine today.
	func validationIssues() -> [SigningCapability.Issue] {
		components.compactMap { component in
			guard component.kind.requiresProfile else {
				guard !component.hasExecutable else { return nil }
				return SigningCapability.Issue(
					code: .nestedComponentInvalid,
					severity: .advisory,
					title: .localized("Nested component has no executable"),
					detail: String.localized(
						"“%@” has no readable executable. It will be signed as a resource.",
						arguments: component.path
					)
				)
			}

			guard component.identifier?.isEmpty == false else {
				return SigningCapability.Issue(
					code: .bundleIdentifierMissing,
					severity: .blocking,
					status: .invalid,
					title: .localized("Extension has no identifier"),
					detail: String.localized(
						"“%@” has no CFBundleIdentifier, so no provisioning profile can cover it.",
						arguments: component.path
					),
					remediation: .localized("Remove the extension, or replace the app with a complete copy.")
				)
			}

			guard !component.hasExecutable else { return nil }
			return SigningCapability.Issue(
				code: .executableUnavailable,
				severity: .blocking,
				status: .invalid,
				title: .localized("Extension has no executable"),
				detail: String.localized(
					"“%@” declares no readable executable, so iOS would refuse to load it after install.",
					arguments: component.path
				),
				remediation: .localized("Remove the extension, or replace the app with a complete copy.")
			)
		}
	}

	// MARK: Discovery

	/// Locations that hold executable nested code, relative to the app bundle.
	private static let roots = ["PlugIns", "Extensions", "Watch", "Frameworks", "Library/Frameworks"]

	/// Bounded so a pathological tree cannot turn discovery into a crawl.
	private static let maximumDepth = 4

	private static func _discover(in appBundle: URL) -> [Component] {
		let manager = FileManager.default
		var found: [Component] = []
		var seen = Set<String>()

		func add(_ url: URL, kind: Kind) {
			let path = _relativePath(of: url, in: appBundle)
			guard !path.isEmpty, seen.insert(path.lowercased()).inserted else { return }
			found.append(_component(at: url, path: path, kind: kind, manager: manager))
		}

		for root in roots {
			let directory = root.split(separator: "/").reduce(appBundle) { $0.appendingPathComponent(String($1)) }
			var isDirectory: ObjCBool = false
			guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
				continue
			}
			_walk(directory, depth: 0, in: appBundle, add: add, manager: manager)
		}

		// Loose dylibs sit next to the executable, and injected ones can land anywhere the
		// tweak pipeline put them. They are collected last so their order never depends on
		// directory enumeration.
		if let contents = try? manager.contentsOfDirectory( // try? ok: an unreadable bundle is reported by the executable check
			at: appBundle,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		) {
			for url in contents where url.pathExtension.lowercased() == "dylib" {
				add(url, kind: .dylib)
			}
		}

		return found.sorted { lhs, rhs in
			if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
			return lhs.path < rhs.path
		}
	}

	private static func _walk(
		_ directory: URL,
		depth: Int,
		in appBundle: URL,
		add: (URL, Kind) -> Void,
		manager: FileManager
	) {
		guard depth < maximumDepth else { return }
		guard let contents = try? manager.contentsOfDirectory( // try? ok: an unreadable directory contributes nothing
			at: directory,
			includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
			options: [.skipsHiddenFiles]
		) else { return }

		for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
			let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) // try? ok: unreadable entry is skipped
			// A symlink is never a nested bundle: following one can both loop and duplicate a
			// component that already exists under its real path.
			guard values?.isSymbolicLink != true, values?.isDirectory == true else {
				if url.pathExtension.lowercased() == "dylib" { add(url, .dylib) }
				continue
			}

			let name = url.lastPathComponent
			if name.hasSuffix(".appex") {
				let insideWatch = _relativePath(of: url, in: appBundle).hasPrefix("Watch/")
				add(url, insideWatch ? .watchExtension : (depth == 0 ? .appExtension : .plugin))
				_walk(url, depth: depth + 1, in: appBundle, add: add, manager: manager)
			} else if name.hasSuffix(".app") {
				add(url, _relativePath(of: url, in: appBundle).hasPrefix("Watch/") ? .watchApp : .embeddedApp)
				_walk(url, depth: depth + 1, in: appBundle, add: add, manager: manager)
			} else if name.hasSuffix(".framework") {
				add(url, .framework)
			} else {
				_walk(url, depth: depth + 1, in: appBundle, add: add, manager: manager)
			}
		}
	}

	private static func _relativePath(of url: URL, in base: URL) -> String {
		let basePath = base.standardizedFileURL.path
		let path = url.standardizedFileURL.path
		guard path.hasPrefix(basePath) else { return "" }
		return String(path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
	}

	private static func _info(at bundle: URL) -> [String: Any]? {
		let plistURL = bundle.appendingPathComponent("Info.plist")
		guard let data = try? Data(contentsOf: plistURL) else { return nil } // try? ok: a missing plist means "no identifier", which is reported
		guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) // try? ok: an unreadable plist means "no identifier", which is reported
		else { return nil }
		return plist as? [String: Any]
	}

	private static func _component(at url: URL, path: String, kind: Kind, manager: FileManager) -> Component {
		let info = _info(at: url)
		let identifier = info?["CFBundleIdentifier"] as? String
		// `CFBundleExecutable` is the authoritative name; the bundle name without its
		// extension is the documented fallback when the key is absent.
		let executableName = info?["CFBundleExecutable"] as? String
			?? url.deletingPathExtension().lastPathComponent
		let executablePath = url.appendingPathComponent(executableName).path
		let hasExecutable = manager.isExecutableFile(atPath: executablePath)

		return Component(path: path, kind: kind, identifier: identifier, hasExecutable: hasExecutable)
	}
}
