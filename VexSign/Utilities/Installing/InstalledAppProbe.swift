//
//  InstalledAppProbe.swift
//  VexSign
//
//  What the device actually has installed.
//
//  The install paths used to call an install "done" when installd's progress counter fell back
//  to zero. iOS rolls an install back when it rejects the signature or the provisioning
//  profile, and the counter reaches zero either way — so the app celebrated failures.
//
//  This probe is the missing evidence: `LSApplicationProxy` tells us whether the bundle is on
//  the device, in which version, and whether it is still a placeholder. Every lookup is guarded
//  and every absent answer is `nil` — "cannot tell" — because a probe that guesses is worse than
//  no probe at all.
//

import Foundation
import NimbleExtensions
import ObjectiveC

// MARK: - Evidence

/// What the device reports for one bundle identifier.
struct InstalledApp: Equatable, Sendable {
	let bundleIdentifier: String
	let isInstalled: Bool
	/// A placeholder is an app iOS has registered but not finished installing.
	let isPlaceholder: Bool
	let version: String?
	let build: String?
	let bundleURL: URL?

	init(
		bundleIdentifier: String,
		isInstalled: Bool,
		isPlaceholder: Bool = false,
		version: String? = nil,
		build: String? = nil,
		bundleURL: URL? = nil
	) {
		self.bundleIdentifier = bundleIdentifier
		self.isInstalled = isInstalled
		self.isPlaceholder = isPlaceholder
		self.version = version
		self.build = build
		self.bundleURL = bundleURL
	}
}

/// Where an app stands relative to the version we expect. The library renders this;
// only derives it, from the same evidence the confirmation engine uses.
enum InstalledState: Equatable, Sendable {
	case installed
	/// On the device, but reporting a different version than expected.
	case installedOtherVersion(String?)
	case notInstalled
	/// No usable evidence: the probe is unavailable, or the app is still a placeholder.
	case unknown

	static func derive(from probe: InstalledApp?, expecting version: String?) -> InstalledState {
		guard let probe else { return .unknown }
		if probe.isPlaceholder { return .unknown }
		guard probe.isInstalled else { return .notInstalled }

		// A version we cannot compare is not a mismatch.
		guard let version, let deviceVersion = probe.version else { return .installed }
		return deviceVersion == version ? .installed : .installedOtherVersion(deviceVersion)
	}

	var title: String {
		switch self {
		case .installed:
			.localized("Installed")
		case .installedOtherVersion(let version):
			version.map { .localized("Installed (version %@)", arguments: $0) }
				?? .localized("Installed (other version)")
		case .notInstalled:
			.localized("Not installed")
		case .unknown:
			.localized("Unknown")
		}
	}
}

// MARK: - Probe

protocol InstalledAppProbing: Sendable {
	/// `nil` when the device cannot answer — never a `false`/`true` guess.
	func installedApp(for bundleIdentifier: String) -> InstalledApp?
}

/// Reads `LSApplicationProxy`. The selector names are base64-encoded the same way as the other
/// private lookups in this app (`UIApplication+open_private`), and every one is checked with
/// `responds(to:)` before use.
struct InstalledAppProbe: InstalledAppProbing {
	func installedApp(for bundleIdentifier: String) -> InstalledApp? {
		guard
			!bundleIdentifier.isEmpty,
			let proxyClass = Self._proxyClass(),
			let identifierSelector = Self._selector("YXBwbGljYXRpb25Qcm94eUZvcklkZW50aWZpZXI6"), // applicationProxyForIdentifier:
			// A class method, so `instancesRespond(to:)` would look in the wrong place — and
			// calling `perform` on a selector the class does not have raises instead of returning nil.
			class_getClassMethod(proxyClass, identifierSelector) != nil,
			let proxy = proxyClass.perform(identifierSelector, with: bundleIdentifier)?
				.takeUnretainedValue() as? NSObject
		else {
			return nil
		}

		guard Self._string(proxy, "YnVuZGxlSWRlbnRpZmllcg==") == bundleIdentifier,
			let isInstalled = Self._bool(proxy, "aXNJbnN0YWxsZWQ=") else {
			// Verify the proxy's identity too. Container hooks or a stale lookup must
			// never turn evidence for the host/another app into a guest install.
			return nil
		}

		return InstalledApp(
			bundleIdentifier: bundleIdentifier,
			isInstalled: isInstalled,
			isPlaceholder: Self._bool(proxy, "aXNQbGFjZWhvbGRlcg==") ?? false,
			version: Self._string(proxy, "c2hvcnRWZXJzaW9uU3RyaW5n"),
			build: Self._string(proxy, "YnVuZGxlVmVyc2lvbg=="),
			bundleURL: Self._url(proxy, "YnVuZGxlVVJM")
		)
	}

	// MARK: Private lookups

	private static func _proxyClass() -> NSObject.Type? {
		guard let name = _decode("TFNBcHBsaWNhdGlvblByb3h5") else { return nil }
		return NSClassFromString(name) as? NSObject.Type
	}

	private static func _selector(_ base64: String) -> Selector? {
		_decode(base64).map(NSSelectorFromString)
	}

	private static func _decode(_ base64: String) -> String? {
		guard let data = Data(base64Encoded: base64) else { return nil }
		return String(data: data, encoding: .utf8)
	}

	/// Reads a `BOOL` accessor. `perform` cannot be used here: Objective-C returns a `BOOL` as a
	/// byte, not an object, so KVC is what boxes it correctly — and only when the key exists.
	private static func _bool(_ proxy: NSObject, _ base64: String) -> Bool? {
		guard let key = _decode(base64), proxy.responds(to: NSSelectorFromString(key)) else { return nil }
		return proxy.value(forKey: key) as? Bool
	}

	private static func _string(_ proxy: NSObject, _ base64: String) -> String? {
		guard let key = _decode(base64), proxy.responds(to: NSSelectorFromString(key)) else { return nil }
		return proxy.value(forKey: key) as? String
	}

	private static func _url(_ proxy: NSObject, _ base64: String) -> URL? {
		guard let key = _decode(base64), proxy.responds(to: NSSelectorFromString(key)) else { return nil }
		return proxy.value(forKey: key) as? URL
	}
}
