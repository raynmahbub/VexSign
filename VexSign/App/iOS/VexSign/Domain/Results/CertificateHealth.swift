import Foundation

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
