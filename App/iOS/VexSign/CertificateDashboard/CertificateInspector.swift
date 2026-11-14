import Foundation
import Security

struct CertificateHealth: Identifiable, Sendable {
    enum Revocation: String, Sendable { case good, revoked, unknown }
    let id: String
    let name: String
    let teamID: String
    let teamName: String
	let expires: Date
	/// The leaf certificate can expire before the provisioning profile and is the
	/// date that most directly explains a signing failure.
	let certificateExpires: Date?
	let deviceCount: Int
    let allDevices: Bool
    let applicationIdentifier: String
    let push: Bool
    let debugEntitlement: Bool
    let entitlements: String
    let provision: String
    let revocation: Revocation
    let checkedAt: Date
	let detail: String
	/// What the revocation check established, kept apart from `revocation` so that "no
	/// answer" stays distinguishable from "not asked" and "cannot be asked".
	var revocationEvidence: CertificateRevocationEvidence = .notChecked

	/// The single status the rest of the app shows for this certificate.
	func assessment(now: Date = Date()) -> CertificateStatusAssessment {
		CertificateStatusAssessment.assess(
			.init(
				certificateExpiry: certificateExpires,
				profileExpiry: expires,
				revokedOnRecord: revocation == .revoked,
				evidence: revocationEvidence
			),
			now: now
		)
	}

    var effectiveExpiry: Date { min(expires, certificateExpires ?? expires) }
    var daysRemaining: Int { Int(floor(effectiveExpiry.timeIntervalSinceNow / 86_400)) }

    /// 0-100 summary of the two things that make a certificate unusable: a revoked
    /// certificate is worthless however long it lasts, and a certificate that has already
    /// expired is equally so. OCSP Unknown is not Good, so it scores below it.
    var score: Int {
        guard effectiveExpiry > Date(), revocation != .revoked else { return 0 }
        let base = revocation == .good ? 100 : 60
        return max(0, base - (daysRemaining < 7 ? 40 : daysRemaining < 30 ? 20 : 0))
    }

    /// Share-safe summary: includes entitlement names but deliberately omits
    /// identifiers, profile payloads, entitlement values, and certificate data.
    var redactedHealthCard: String {
        let entitlementNames: [String]
        if let data = entitlements.data(using: .utf8),
           let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] { // try? ok: diagnostic share text; unparsable payload lists no entitlement names
            entitlementNames = plist.keys.sorted()
        } else {
            entitlementNames = []
        }
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime]
        return [
            "VexSign Certificate Health Card",
            "Generated: \(date.string(from: checkedAt))",
            "OCSP status: \(revocation.rawValue.capitalized)",
            "Provisioning profile expiry: \(date.string(from: expires))",
            "Signing certificate expiry: \(certificateExpires.map { date.string(from: $0) } ?? "Unavailable")",
            "Device scope: \(allDevices ? "All devices" : "Limited device profile (\(deviceCount) devices)")",
            "Device UDID match: Not assessed by this report",
            "Entitlements: \(entitlementNames.isEmpty ? "None parsed" : entitlementNames.joined(separator: ", "))",
            "\nThis summary omits certificate/profile contents, account identifiers, bundle identifiers, device UDIDs, and entitlement values. OCSP Unknown does not mean valid."
        ].joined(separator: "\n")
    }
}

enum CertificateInspector {
    /// Reads a profile's descriptive payload, NOT proof of its CMS signature.
    /// Signing eligibility still belongs to the existing signing preflight.
    static func inspect(id: String, name: String, p12: URL, password: String, profile: URL, online: Bool) async throws -> CertificateHealth {
        try await Task.detached(priority: .utility) {
            let data = try CertificateInputReader.read(profile)
            guard data.count <= 10 * 1_024 * 1_024,
                  let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
                throw RepositoryError.invalid("Invalid provisioning profile.")
            }
            let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
            guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                  let expiry = plist["ExpirationDate"] as? Date else { throw RepositoryError.invalid("Profile has no expiration date.") }
			let entitlements = (plist["Entitlements"] as? [String: Any]) ?? [:]
			let entitlementData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)

			// Import the P12 even for an offline inspection. This validates the saved
			// password and lets the UI distinguish certificate expiry from profile expiry.
			let keyData = try CertificateInputReader.read(p12)
			var imported: CFArray?
			let importResult = SecPKCS12Import(keyData as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &imported)
			guard importResult == errSecSuccess,
				  let items = imported as? [[String: Any]],
				  let item = items.first,
				  let chain = item[kSecImportItemCertChain as String] as? [SecCertificate],
				  !chain.isEmpty else {
				throw SecureSecretStore.Failure(status: importResult == errSecSuccess ? errSecDecode : importResult)
			}
			let certificateExpires = Self.notAfter(chain[0])

			var status: CertificateHealth.Revocation = .unknown
			var evidence: CertificateRevocationEvidence = .notChecked
			var detail = "OCSP has not been checked. Profile metadata is not signature verification."
			if online {
				// A check that cannot be set up is a property of this certificate and device, not
				// a failure of the inspection: the dates above are still worth reporting.
				let requestedPolicy: SecPolicy? = SecPolicyCreateRevocation(CFOptionFlags(kSecRevocationOCSPMethod | kSecRevocationRequirePositiveResponse))
				var trust: SecTrust?
				if let revocationPolicy = requestedPolicy,
				   SecTrustCreateWithCertificates(chain as CFArray, [SecPolicyCreateBasicX509(), revocationPolicy] as CFArray, &trust) == errSecSuccess,
				   let trust {
					SecTrustSetNetworkFetchAllowed(trust, true)
					var error: CFError?
					if SecTrustEvaluateWithError(trust, &error) {
						evidence = .good(checkedAt: Date())
						detail = "System trust evaluation passed with positive OCSP evidence. This is not a guarantee of installation eligibility."
					} else if let error {
						// Only an explicit revocation answer counts as revoked. A check that
						// could not finish, or failed for another reason, proves nothing.
						evidence = CertificateRevocationEvidence.classify(trustErrorCode: Int(CFErrorGetCode(error)))
						detail = CFErrorCopyDescription(error) as String
					} else {
						evidence = .inconclusive
						detail = "Trust evaluation failed without a reason. Revocation status is not known."
					}
				} else {
					evidence = .unsupported
					detail = "A revocation check could not be set up for this certificate."
				}
				switch evidence {
				case .good: status = .good
				case .revoked: status = .revoked
				case .notChecked, .responderUnreachable, .unsupported, .inconclusive: status = .unknown
				}
			}
			return CertificateHealth(id: id, name: name,
				teamID: (plist["TeamIdentifier"] as? [String])?.joined(separator: ", ") ?? "Unknown",
				teamName: plist["TeamName"] as? String ?? "Unknown",
				expires: expiry,
				certificateExpires: certificateExpires,
				deviceCount: (plist["ProvisionedDevices"] as? [String])?.count ?? 0,
				allDevices: (plist["ProvisionsAllDevices"] as? Bool) ?? false,
				applicationIdentifier: entitlements["application-identifier"] as? String ?? "Unknown",
				push: entitlements["aps-environment"] != nil,
				debugEntitlement: (entitlements["get-task-allow"] as? Bool) ?? false,
				entitlements: String(decoding: entitlementData, as: UTF8.self),
				provision: String(decoding: plistData, as: UTF8.self),
				revocation: status, checkedAt: Date(), detail: detail, revocationEvidence: evidence)
        }.value
    }

	/// Reads the leaf certificate's notAfter date straight out of its DER
	/// encoding. `SecCertificateCopyValues` and the `kSecOID*` keys it would
	/// need are macOS-only, so on iOS the ASN.1 structure has to be walked
	/// manually — this reaches the Validity sequence and decodes its times.
	///
	/// Internal rather than private since the local install server's
	/// identity (`LocalTLSIdentity`) needs the same reading, and a second ASN.1
	/// walker in the app would be one too many.
	static func notAfter(_ certificate: SecCertificate) -> Date? {
		var record = DERReader([UInt8](SecCertificateCopyData(certificate) as Data))
		// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
		guard var tbs = record.sequence() else { return nil }
		// TBSCertificate ::= SEQUENCE { [0] version?, serialNumber, signature,
		//                                issuer, validity, subject, ... }
		if tbs.peekTag() == 0xA0 { _ = tbs.skip() }  // optional version record
		guard tbs.skip(), tbs.skip(), tbs.skip(),  // serialNumber, signature, issuer
			var validity = tbs.sequence() else { return nil }
		// Validity ::= SEQUENCE { notBefore Time, notAfter Time }
		guard validity.skip(), let notAfter = validity.time() else { return nil }
		return notAfter
	}

	/// Minimal DER (ASN.1) reader — just enough to reach the Validity sequence
	/// of an X.509 certificate. Not a general parser: unknown records are
	/// skipped by length, which is all certificate walking needs.
	private struct DERReader {
		private let bytes: [UInt8]
		private var position = 0

		init(_ bytes: [UInt8]) { self.bytes = bytes }

		/// The tag of the next record, without consuming it.
		func peekTag() -> UInt8? {
			position < bytes.count ? bytes[position] : nil
		}

		/// Consumes the next record and returns its tag and content bytes.
		private mutating func next() -> (tag: UInt8, content: [UInt8])? {
			guard position + 2 <= bytes.count else { return nil }
			let tag = bytes[position]
			position += 1
			var length = Int(bytes[position])
			position += 1
			if length & 0x80 != 0 {  // long-form length
				let byteCount = length & 0x7f
				guard byteCount > 0, byteCount <= 4, position + byteCount <= bytes.count else { return nil }
				length = 0
				for _ in 0..<byteCount {
					length = (length << 8) | Int(bytes[position])
					position += 1
				}
			}
			guard position + length <= bytes.count else { return nil }
			defer { position += length }
			return (tag, Array(bytes[position..<(position + length)]))
		}

		/// Skips the next record, whatever it is.
		mutating func skip() -> Bool { next() != nil }

		/// Reads a SEQUENCE (tag 0x30) and returns a reader over its contents.
		mutating func sequence() -> DERReader? {
			guard let record = next(), record.tag == 0x30 else { return nil }
			return DERReader(record.content)
		}

		/// Reads an ASN.1 Time value: UTCTime (tag 0x17) or GeneralizedTime
		/// (tag 0x18), per RFC 5280 §4.1.2.5.
		mutating func time() -> Date? {
			guard let record = next(), record.tag == 0x17 || record.tag == 0x18 else { return nil }
			guard let text = String(bytes: record.content, encoding: .ascii) else { return nil }
			let normalized: String
			if record.tag == 0x17 {
				// UTCTime "YYMMDDHHMMSSZ" — expand the two-digit year
				// (00–49 → 20xx, 50–99 → 19xx).
				guard text.count == 13, let year = Int(text.prefix(2)) else { return nil }
				normalized = (year < 50 ? "20" : "19") + text
			} else {
				// GeneralizedTime "YYYYMMDDHHMMSSZ" (fractional seconds, if
				// present, are dropped).
				guard text.count >= 15 else { return nil }
				normalized = String(text.prefix(14)) + "Z"
			}
			let formatter = DateFormatter()
			formatter.locale = Locale(identifier: "en_US_POSIX")
			formatter.timeZone = TimeZone(secondsFromGMT: 0)
			formatter.dateFormat = "yyyyMMddHHmmss'Z'"
			return formatter.date(from: normalized)
		}
	}
}
