//
//  LocalCAProfile.swift
//  VexSign
//
//  Generates a .mobileconfig configuration profile containing the local Root Certificate
//  Authority (PayloadType: com.apple.security.root) so iOS devices can trust local HTTPS
//  installations offline without relying on third-party cloud SSL providers.
//

import Foundation
import UIKit

enum LocalCAProfile {
	/// Extracts the Root CA from server.crt and builds a .mobileconfig profile.
	static func exportProfile() -> URL? {
		guard let certURL = ServerInstaller.getUrl("server", ext: "crt"),
		      let certData = try? Data(contentsOf: certURL),
		      let pemString = String(data: certData, encoding: .utf8) else {
			return nil
		}

		guard let derData = extractRootCertificateDER(from: pemString) else {
			return nil
		}

		let host = ServerInstaller.readCommonName() ?? "127.0.0.1"
		let displayName = "VexSign Local Root CA (\(host))"

		guard let profileData = buildMobileConfig(caCertificateDER: derData, displayName: displayName) else {
			return nil
		}

		let tempDir = FileManager.default.uniqueTemporaryDirectory("LocalCAProfile")
		try? FileManager.default.createDirectoryIfNeeded(at: tempDir)
		let profileURL = tempDir.appendingPathComponent("VexSign-LocalCA.mobileconfig")

		do {
			try profileData.write(to: profileURL)
			return profileURL
		} catch {
			return nil
		}
	}

	/// Extracts the DER bytes of the root (last) certificate from a PEM bundle.
	static func extractRootCertificateDER(from pem: String) -> Data? {
		let beginMarker = "-----BEGIN CERTIFICATE-----"
		let endMarker = "-----END CERTIFICATE-----"

		var certificates: [Data] = []
		var scanner = pem

		while let beginRange = scanner.range(of: beginMarker),
		      let endRange = scanner.range(of: endMarker, range: beginRange.upperBound..<scanner.endIndex) {
			let base64String = scanner[beginRange.upperBound..<endRange.lowerBound]
				.components(separatedBy: .whitespacesAndNewlines)
				.joined()
			if let data = Data(base64Encoded: base64String) {
				certificates.append(data)
			}
			scanner = String(scanner[endRange.upperBound...])
		}

		// The root/CA cert is the last cert in the chain.
		return certificates.last
	}

	/// Builds an Apple configuration profile (com.apple.security.root).
	static func buildMobileConfig(caCertificateDER: Data, displayName: String) -> Data? {
		let rootPayloadUUID = UUID().uuidString
		let profileUUID = UUID().uuidString

		let rootPayload: [String: Any] = [
			"PayloadType": "com.apple.security.root",
			"PayloadVersion": 1,
			"PayloadIdentifier": "com.vexsign.localca.root.\(rootPayloadUUID)",
			"PayloadUUID": rootPayloadUUID,
			"PayloadDisplayName": displayName,
			"PayloadDescription": "Installs the VexSign Local Root CA for offline OTA HTTPS app installations.",
			"PayloadContent": caCertificateDER
		]

		let profile: [String: Any] = [
			"PayloadType": "Configuration",
			"PayloadVersion": 1,
			"PayloadIdentifier": "com.vexsign.localca.profile.\(profileUUID)",
			"PayloadUUID": profileUUID,
			"PayloadDisplayName": displayName,
			"PayloadDescription": "Configures trust for the VexSign offline local HTTPS server.",
			"PayloadOrganization": "VexSign",
			"PayloadContent": [rootPayload]
		]

		return try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
	}
}
