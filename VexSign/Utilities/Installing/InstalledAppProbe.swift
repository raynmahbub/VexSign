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
//  This probe is the missing evidence: LaunchServices records and proxies report whether the
//  bundle is on the device, its version, and whether it is still a placeholder. A positive-only
//  registry fallback handles filtered per-app lookups; missing or ambiguous answers remain `nil`
//  ("cannot tell") rather than becoming a guess of installed or absent.
//

import Foundation
import Dispatch
import os
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
	/// An installation attempt for this identifier is in flight right now.
	///
	/// A lifecycle state, not a device reading: `derive` never returns it, because a probe
	/// answers "what is on the device", and mid-install the honest answer is that the question
	/// is still open. It exists because without it the library published a negative — a stale
	/// "Not installed", or the "Unknown" a filtered lookup returns — for the whole window iOS
	/// was actually installing, which reads as a failed install to the user.
	///
	/// It is a request being monitored, not proof of installation: it becomes `installed` only
	/// on the confirmation engine's evidence, and `unknown`/`notInstalled` when the attempt ends
	/// without any.
	case installing

	/// Whether this state is a transient installation lifecycle state rather than a device answer.
	var isTransient: Bool { self == .installing }

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
		case .installing:
			.localized("Installing")
		}
	}
}

// MARK: - Probe

protocol InstalledAppProbing: Sendable {
	/// `nil` when the device cannot answer — never a `false`/`true` guess.
	func installedApp(for bundleIdentifier: String) -> InstalledApp?
}

/// A synchronous private API cannot be cancelled once entered. Run it away from
/// the caller and bound how long workflows wait for its result.
private final class InstalledAppProbeContinuation: Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<InstalledApp?, Never>?>(initialState: nil)

    func install(_ continuation: CheckedContinuation<InstalledApp?, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resolve(_ result: InstalledApp?) {
        let pending = continuation.withLock { slot -> CheckedContinuation<InstalledApp?, Never>? in
            defer { slot = nil }
            return slot
        }
        pending?.resume(returning: result)
    }
}

extension InstalledAppProbing {
    func installedAppWithTimeout(
        for bundleIdentifier: String,
        timeout: TimeInterval = 1
    ) async -> InstalledApp? {
        await withCheckedContinuation { (continuation: CheckedContinuation<InstalledApp?, Never>) in
            let once = InstalledAppProbeContinuation()
            once.install(continuation)
            DispatchQueue.global(qos: .utility).async {
                once.resolve(self.installedApp(for: bundleIdentifier))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
                once.resolve(nil)
            }
        }
    }
}

/// Resolves installed-app evidence from LaunchServices bundle records, per-app proxies, and a
/// positive-only installed-app registry fallback. Private selectors are dynamically checked
/// before use; missing or filtered lookups remain unknown rather than proving absence.
struct InstalledAppProbe: InstalledAppProbing {
    /// Do not let simultaneous callers fan out into multiple uninterruptible
    /// LaunchServices calls. If one call wedges, later requests fail closed.
    private static let _probePermit = DispatchSemaphore(value: 1)

    func installedApp(for bundleIdentifier: String) -> InstalledApp? {
        guard !bundleIdentifier.isEmpty, !Thread.isMainThread,
              Self._probePermit.wait(timeout: .now()) == .success else { return nil }
        defer { Self._probePermit.signal() }
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
                ?? Self._listedApplication(bundleIdentifier)
        }
        // Never substitute host/another app's proxy, including in a hooked runtime.
        guard Self._string(proxy, "YnVuZGxlSWRlbnRpZmllcg==") == bundleIdentifier else {
            return Self._listedApplication(bundleIdentifier)
        }
        guard let installed = Self._bool(proxy, "aXNJbnN0YWxsZWQ=") ?? workspaceInstalled else {
            return Self._listedApplication(bundleIdentifier)
        }
        let candidate = InstalledApp(bundleIdentifier: bundleIdentifier,
            isInstalled: installed,
            isPlaceholder: Self._bool(proxy, "aXNQbGFjZWhvbGRlcg==") ?? false,
            version: Self._string(proxy, "c2hvcnRWZXJzaW9uU3RyaW5n"),
            build: Self._string(proxy, "YnVuZGxlVmVyc2lvbg=="),
            bundleURL: Self._url(proxy, "YnVuZGxlVVJM"))
        return Self.resolve(bundleIdentifier, proxy: candidate, workspaceInstalled: workspaceInstalled)
            ?? Self._listedApplication(bundleIdentifier)
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

    /// Current LaunchServices builds may filter per-bundle lookups while still
    /// returning the installed-app registry. Use that registry as a positive-only
    /// fallback; an incomplete/filtered list must never establish absence.
    private static func _listedApplication(_ identifier: String) -> InstalledApp? {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              class_getClassMethod(workspaceClass, NSSelectorFromString("defaultWorkspace")) != nil,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?
                .takeUnretainedValue() as? NSObject else { return nil }
        let selector = NSSelectorFromString("allInstalledApplications")
        guard workspace.responds(to: selector),
              let applications = workspace.perform(selector)?.takeUnretainedValue() as? [NSObject],
              let proxy = applications.first(where: { _string($0, "YnVuZGxlSWRlbnRpZmllcg==") == identifier }) else {
            return nil
        }
        return listedApplication(
            identifier,
            returnedIdentifier: _string(proxy, "YnVuZGxlSWRlbnRpZmllcg=="),
            isPlaceholder: _bool(proxy, "aXNQbGFjZWhvbGRlcg=="),
            version: _string(proxy, "c2hvcnRWZXJzaW9uU3RyaW5n"),
            build: _string(proxy, "YnVuZGxlVmVyc2lvbg=="),
            bundleURL: _url(proxy, "YnVuZGxlVVJM")
        )
    }

    /// Pure validation for the positive registry result, also covered by tests.
    static func listedApplication(
        _ identifier: String,
        returnedIdentifier: String?,
        isPlaceholder: Bool?,
        version: String? = nil,
        build: String? = nil,
        bundleURL: URL? = nil
    ) -> InstalledApp? {
        guard !identifier.isEmpty, returnedIdentifier == identifier,
              let isPlaceholder else { return nil }
        return InstalledApp(
            bundleIdentifier: identifier,
            isInstalled: !isPlaceholder,
            isPlaceholder: isPlaceholder,
            version: version,
            build: build,
            bundleURL: bundleURL
        )
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
