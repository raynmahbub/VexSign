//
//  EntitlementBuilder.swift
//  VexSign
//
//  Builds the entitlements plist Zsign signs with. Zsign takes a file path, so
//  every option that adds entitlements (JIT today, keychain isolation in
//  `SigningHandler`) ends up writing one; this keeps the merging rules in a
//  single place instead of scattered across the signing pipeline.
//

import Foundation

enum EntitlementBuilder {
	/// Keys that let a sideloaded binary allocate executable memory at runtime.
	/// `dynamic-codesigning` is the one iOS actually enforces for JIT enablers;
	/// the two `com.apple.security.cs.*` keys are what tooling looks for.
	static let jitEntitlementKeys: [String] = [
		"dynamic-codesigning",
		"com.apple.security.cs.allow-jit",
		"com.apple.security.cs.allow-unsigned-executable-memory",
	]

	/// Merges the requested extras into the profile's entitlements.
	///
	/// - Parameters:
	///   - base: Entitlements read from the provisioning profile or a picked file.
	///   - enableJIT: The user's toggle.
	///   - supportsJIT: Whether the selected certificate can carry JIT at all.
	///     A PPQLess certificate never gets the keys, even when the toggle is on.
	static func entitlements(
		base: [String: Any],
		enableJIT: Bool,
		supportsJIT: Bool
	) -> [String: Any] {
		var result = base

		guard enableJIT, supportsJIT else { return result }

		for key in jitEntitlementKeys {
			result[key] = true
		}
		return result
	}

	/// True when the built entitlements differ from the base, i.e. something was added.
	static func addsJIT(base: [String: Any], enableJIT: Bool, supportsJIT: Bool) -> Bool {
		guard enableJIT, supportsJIT else { return false }
		return jitEntitlementKeys.contains { base[$0] as? Bool != true }
	}

	/// Writes an XML entitlements plist Zsign can read.
	@discardableResult
	static func write(_ entitlements: [String: Any], to url: URL) throws -> URL {
		let data = try PropertyListSerialization.data(
			fromPropertyList: entitlements,
			format: .xml,
			options: 0
		)
		try FileManager.default.createDirectoryIfNeeded(at: url.deletingLastPathComponent())
		try data.write(to: url, options: .atomic)
		return url
	}
}
