//
//  SigningVerificationReportBuilder.swift
//  VexSign
//
//  Converts the verifier's own report, plus display-only public metadata from
//  the bundle it just checked, into the bounded value persisted on the task.
//
//  This builder runs only after `SignatureVerifier.Report.requireVerified()`
//  has accepted the output. A failure here can degrade the display fields, but
//  it can never manufacture a verification verdict: `verdict` always comes from
//  the verifier's own report.
//

import Foundation

enum SigningVerificationReportBuilder {
    private static let issueLimit = 32
    private static let fingerprintLimit = 4

    static func make(
        from report: SignatureVerifier.Report,
        bundleAt url: URL,
        componentCount: Int,
        now: Date = Date()
    ) -> SigningVerificationReport {
        var fingerprints: [String] = []
        var architectures = 0
        if let executable = SigningInputValidation.executable(in: url) {
            fingerprints = Array(BundleSignature.read(executableAt: executable).identities
                .map(\.fingerprint).prefix(fingerprintLimit))
            if let data = try? Data(contentsOf: executable, options: .mappedIfSafe), // try? ok: display-only slice count; the verifier already checked every image
               data.count <= 2 * 1024 * 1024 * 1024,
               let images = try? MachOEntitlements.images(in: data) { // try? ok: display-only architecture count; malformed images are rejected by the verifier
                architectures = images.count
            }
        }
        return SigningVerificationReport(
            verdict: report.verdict.rawValue,
            summary: SigningVerificationReport.bounded(report.summary),
            failureCount: report.failures.count,
            warningCount: report.warnings.count,
            issues: Array(report.issues.prefix(issueLimit).map { issue in
                SigningVerificationReport.Issue(
                    code: issue.code.rawValue, severity: issue.severity.rawValue,
                    detail: SigningVerificationReport.bounded(issue.detail),
                    subject: issue.subject.map(SigningVerificationReport.bounded)
                )
            }),
            signerFingerprints: fingerprints,
            architectureCount: architectures,
            componentCount: min(max(componentCount, 0), 1024),
            durationMilliseconds: Int((report.duration * 1000).rounded()),
            verifiedAt: now
        )
    }
}
