//
//  SigningVerificationReport.swift
//  VexSign
//
//  The durable, non-secret result of the post-sign verification pass. This is a
//  domain value only: the builder that reads bundle metadata lives in Services.
//  No private key, password, PKCS#12 content, or absolute path is kept here.
//

import Foundation

struct SigningVerificationReport: Codable, Equatable, Sendable {
    struct Issue: Codable, Equatable, Hashable, Identifiable, Sendable {
        let code: String
        let severity: String
        let detail: String
        let subject: String?

        var id: String { code + "\u{1}" + detail + "\u{1}" + (subject ?? "") }
    }

    let verdict: String
    let summary: String
    let failureCount: Int
    let warningCount: Int
    let issues: [Issue]
    /// SHA-256 fingerprints of the signers the verifier accepted, when readable.
    let signerFingerprints: [String]
    /// Number of Mach-O images in the main executable (one for a thin binary).
    let architectureCount: Int
    /// Number of signed components in the authenticated plan, including the app.
    let componentCount: Int
    let durationMilliseconds: Int
    let verifiedAt: Date

    static let empty = SigningVerificationReport(
        verdict: "unsupported", summary: "No signature verification has run.", failureCount: 0,
        warningCount: 0, issues: [], signerFingerprints: [], architectureCount: 0,
        componentCount: 0, durationMilliseconds: 0, verifiedAt: Date(timeIntervalSince1970: 0)
    )

    /// Diagnostics are persisted and shown in the UI. Bound them and run the
    /// same secret/path redaction as other operation results: an engine line
    /// can contain a password or a container path, and neither belongs here.
    static func bounded(_ text: String) -> String {
        let redacted = OperationOutcome.reason(text) ?? ""
        return String(redacted.prefix(240))
    }
}
