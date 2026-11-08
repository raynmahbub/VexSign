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
        guard !bundleIdentifier.isEmpty else { return nil }
        // Modern LaunchServices records remain usable on devices where the legacy
        // workspace/proxy APIs return filtered false values for installed apps.
        if let record = Self._applicationRecord(bundleIdentifier) {
            return Self.resolve(bundleIdentifier, proxy: nil, workspaceInstalled: nil, applicationRecord: record)
        }
        let workspaceInstalled = Self._workspaceInstalled(bundleIdentifier)
        guard let proxyClass = Self._proxyClass(),
              let selector = Self._selector("YXBwbGljYXRpb25Qcm94eUZvcklkZW50aWZpZXI6"),
              class_getClassMethod(proxyClass, selector) != nil,
              let proxy = proxyClass.perform(selector, with: bundleIdentifier)?.takeUnretainedValue() as? NSObject else {
            return Self.resolve(bundleIdentifier, proxy: nil, workspaceInstalled: workspaceInstalled)
        }
        // Never substitute host/another app's proxy, including in a hooked runtime.
        guard Self._string(proxy, "YnVuZGxlSWRlbnRpZmllcg==") == bundleIdentifier else { return nil }
        guard let installed = Self._bool(proxy, "aXNJbnN0YWxsZWQ=") ?? workspaceInstalled else { return nil }
        let candidate = InstalledApp(bundleIdentifier: bundleIdentifier,
            isInstalled: installed,
            isPlaceholder: Self._bool(proxy, "aXNQbGFjZWhvbGRlcg==") ?? false,
            version: Self._string(proxy, "c2hvcnRWZXJzaW9uU3RyaW5n"),
            build: Self._string(proxy, "YnVuZGxlVmVyc2lvbg=="),
            bundleURL: Self._url(proxy, "YnVuZGxlVVJM"))
        return Self.resolve(bundleIdentifier, proxy: candidate, workspaceInstalled: workspaceInstalled)
    }

    /// A workspace query is independent of the proxy's sometimes stale isInstalled
    /// flag. A registered URL alone is never sufficient positive install evidence.
    static func resolve(_ identifier: String, proxy: InstalledApp?, workspaceInstalled: Bool?, applicationRecord: InstalledApp? = nil) -> InstalledApp? {
        guard !identifier.isEmpty else { return nil }
        if let record = applicationRecord {
            guard record.bundleIdentifier == identifier, record.isInstalled, !record.isPlaceholder else { return nil }
            return record
        }
        if let proxy, proxy.bundleIdentifier != identifier { return nil }
        if let proxy, proxy.isPlaceholder { return proxy }
        if workspaceInstalled == true || proxy?.isInstalled == true {
            return InstalledApp(bundleIdentifier: identifier, isInstalled: true,
                version: proxy?.version, build: proxy?.build, bundleURL: proxy?.bundleURL)
        }
        // Contradictory cached metadata is unknown, not a false Not installed badge.
        if proxy?.bundleURL != nil { return nil }
        // A private query's false result is also returned for restricted/filtered
        // access. Even two legacy negatives cannot establish device-wide absence.
        return nil
    }

    /// Accept only a matching real application record, never an extension, a
    /// placeholder, or a URL obtained independently of a successful record lookup.
    static func installedRecord(_ identifier: String, recordIdentifier: String?,
                                isApplication: Bool, isPlaceholder: Bool?,
                                isSystemPlaceholder: Bool?, version: String?,
                                build: String?, bundleURL: URL?) -> InstalledApp? {
        guard !identifier.isEmpty, recordIdentifier == identifier, isApplication,
              isPlaceholder == false, isSystemPlaceholder != true,
              let bundleURL, bundleURL.isFileURL else { return nil }
        return InstalledApp(bundleIdentifier: identifier, isInstalled: true,
                            version: version, build: build, bundleURL: bundleURL)
    }

    private static func _applicationRecord(_ identifier: String) -> InstalledApp? {
        guard let type = NSClassFromString("LSBundleRecord") as? NSObject.Type,
              let applicationType = NSClassFromString("LSApplicationRecord") else { return nil }
        let selector = NSSelectorFromString("bundleRecordWithBundleIdentifier:allowPlaceholder:error:")
        guard let method = class_getClassMethod(type, selector) else { return nil }
        // This factory returns an autoreleased object. Its BOOL and NSError **
        // arguments require the real ABI; NSObject.perform cannot express them.
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, Bool,
            UnsafeMutablePointer<Unmanaged<AnyObject>?>?) -> Unmanaged<AnyObject>?
        let lookup = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
        guard let record = lookup(type as AnyObject, selector, identifier as NSString, false, nil)?
            .takeUnretainedValue() as? NSObject else { return nil }
        return installedRecord(identifier,
            recordIdentifier: _string(record, "YnVuZGxlSWRlbnRpZmllcg=="),
            isApplication: record.isKind(of: applicationType),
            isPlaceholder: _bool(record, "aXNQbGFjZWhvbGRlcg=="),
            isSystemPlaceholder: _bool(record, "aXNTeXN0ZW1QbGFjZWhvbGRlcg=="),
            version: _string(record, "c2hvcnRWZXJzaW9uU3RyaW5n"),
            build: _string(record, "YnVuZGxlVmVyc2lvbg=="),
            bundleURL: _url(record, "VVJM"))
    }

    private static func _workspaceInstalled(_ identifier: String) -> Bool? {
        guard let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              class_getClassMethod(type, NSSelectorFromString("defaultWorkspace")) != nil,
              let workspace = type.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else { return nil }
        let selector = NSSelectorFromString("applicationIsInstalled:")
        guard workspace.responds(to: selector), let implementation = workspace.method(for: selector) else { return nil }
        // BOOL is not an Objective-C object: perform/KVC cannot invoke this signature.
        typealias Query = @convention(c) (AnyObject, Selector, NSString) -> Bool
        return unsafeBitCast(implementation, to: Query.self)(workspace, selector, identifier as NSString)
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
