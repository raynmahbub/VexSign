//
//  AntiRevokeManager.swift
//  VexSign
//
//  DNS anti-revoke, done honestly. Apple's device-side revocation check resolves a handful of
//  verification hosts (ocsp.apple.com, …). Stock iOS — no MDM, no jailbreak — can only reroute
//  DNS one way: a per-device DNS configuration profile the user installs themselves.
//
//  A profile alone does not block anything. It pins a DNS-over-HTTPS server, and blocking
//  happens only if that server refuses to answer Apple's revocation hosts. So this builder
//  takes the endpoint from the user (a sinkhole DoH they trust) instead of shipping our own
//  hosted service. It also cannot un-revoke a certificate Apple has already revoked.
//

import Foundation
import UIKit
import NimbleExtensions

// MARK: - Manager
final class AntiRevokeManager {
	static let shared = AntiRevokeManager()

	/// Apple's certificate-verification hosts. These are what the pinned DoH server has to
	/// sinkhole for the protection to do anything. Dynamically synced via NovaDNSDynamic.
	static var revocationHosts: [String] {
		NovaDNSDynamic.loadCachedRules().blockedHosts
	}

	private init() {}

	// MARK: Profile generation

	/// Where the generated profile lives. `nil` before the first successful build.
	var profileURL: URL? {
		let url = storageURL.appendingPathComponent("AntiRevoke.mobileconfig")
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}

	private var storageURL: URL {
		URL.documentsDirectory.appendingPathComponent("AntiRevoke", isDirectory: true)
	}

	/// Builds a `com.apple.dnsSettings.managed` profile pinning the given DNS-over-HTTPS server,
	/// and writes it to storage. `serverURL` must be a valid `https://` DoH endpoint.
	///
	/// `nonisolated`: pure Foundation path/property-list math, safe off the main actor.
	/// UI callers wrap it in `MainActor.run`.
	nonisolated func buildProfile(serverName: String, serverURL: String) throws -> URL {
		guard
			let endpoint = URL(string: serverURL),
			endpoint.scheme?.lowercased() == "https"
		else {
			throw AntiRevokeError.invalidEndpoint
		}

		let fileManager = FileManager.default
		let directory = URL.documentsDirectory.appendingPathComponent("AntiRevoke", isDirectory: true)
		try fileManager.createDirectoryIfNeeded(at: directory)

		let baseIdentifier = "com.vexsign.antirevoke.dns.\(Bundle.main.bundleIdentifier ?? "vexsign")"
		let payloadIdentifier = baseIdentifier + ".managed"

		let payload: [String: Any] = [
			"PayloadType": "com.apple.dnsSettings.managed",
			"PayloadUUID": UUID().uuidString,
			"PayloadIdentifier": payloadIdentifier,
			"PayloadVersion": 1,
			"PayloadDisplayName": "VexSign Anti-Revoke DNS",
			"DNSSettings": [
				"DNSString": serverName,
				"DNSProtocol": "HTTPS",
				"ServerName": serverName,
				"ServerURL": serverURL,
				"SupportsWildcard": true,
				// DoH answers without a fallback resolver, so a down endpoint never silently
				// leaks queries through the default gateway.
				"ProhibitDisablement": true,
				"ProhibitEncryptedDNS": false
			]
		]

		let profile: [String: Any] = [
			"PayloadType": "Configuration",
			"PayloadUUID": UUID().uuidString,
			"PayloadIdentifier": payloadIdentifier,
			"PayloadVersion": 1,
			"PayloadDisplayName": "VexSign Anti-Revoke",
			"PayloadDescription": "Pins DNS-over-HTTPS so Apple's certificate revocation lookups are answered by the chosen resolver.",
			"PayloadContent": [payload],
			"PayloadRemovalDisallowed": false
		]

		guard let data = try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0) else {
			throw AntiRevokeError.serializationFailed
		}

		let url = directory.appendingPathComponent("AntiRevoke.mobileconfig")
		try data.write(to: url, options: .atomic)
		return url
	}

	// MARK: Install

	/// iOS only installs profiles from Settings, so the flow is share → Save to Files → open →
	/// Install. The sheet presents the generated profile.
	static func shareProfile(_ url: URL) {
		UIAlertController.showAlertWithOptions(
			title: .localized("Install Anti-Revoke Profile"),
			message: .localized("Save the profile to Files (or AirDrop it), tap it there, then choose Install in Settings. Apple never installs a profile straight from an app."),
			actions: [
				(.localized("Share Profile"), .default, {
					UIActivityViewController.show(activityItems: [url])
				}),
				(.localized("Cancel"), .cancel, nil)
			]
		)
	}

	/// Deletes the generated profile and its folder.
	func removeGeneratedProfile() {
		try? FileManager.default.removeItem(at: storageURL)
	}
}

// MARK: - Errors
enum AntiRevokeError: LocalizedError {
	case invalidEndpoint
	case serializationFailed

	var errorDescription: String? {
		switch self {
		case .invalidEndpoint:
			.localized("Enter an https:// DNS-over-HTTPS endpoint.")
		case .serializationFailed:
			.localized("The profile could not be written.")
		}
	}
}
