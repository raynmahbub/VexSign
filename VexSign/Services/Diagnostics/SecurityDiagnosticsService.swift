//
//  SecurityDiagnosticsService.swift
//  VexSign
//
//  A read-only view of the security evidence the app actually has. Each row is
//  produced by calling the same validator the product uses — signature structure,
//  provisioning-profile CMS, release-manifest trust, archive policy, transport
//  policy and log redaction — and every row says when it could not check anything.
//
//  There is deliberately no score: a missing artifact is `unsupported`, not a
//  failure, and a warning is not presented as a pass. This view cannot make an
//  install decision; it only reports what has been checked on this device.
//

import Foundation
import NimbleExtensions

enum SecurityCheckStatus: String, Equatable, Sendable {
    case passed
    case warning
    case failed
    case unknown
    case unsupported
}

struct SecurityCheck: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: SecurityCheckStatus
    let detail: String
}

@MainActor
protocol SecurityDiagnosticsProviding: AnyObject {
    func checks() -> [SecurityCheck]
}

@MainActor
final class SecurityDiagnosticsService: SecurityDiagnosticsProviding {
    private let bundle: Bundle
    private let allowInsecureHTTP: Bool
    private let logProbe: () -> String
    private let signedBundleURL: () -> URL?
    private let profileData: () -> Data?
    private let archiveURL: () -> URL?
    private let manifestEnvelope: () -> Data?
    private let supportedOSVersion: String
    private let now: () -> Date
    private let recorder: DiagnosticRecorder?
    private var reportedFailures: Set<String> = []

    init(
        bundle: Bundle = .main,
        allowInsecureHTTP: Bool? = nil,
        logProbe: @escaping () -> String = {
            LogRedaction.redact("security-diagnostic-probe token=not-a-real-token")
        },
        signedBundleURL: @escaping () -> URL? = { nil },
        profileData: @escaping () -> Data? = { nil },
        archiveURL: @escaping () -> URL? = { nil },
        manifestEnvelope: @escaping () -> Data? = { nil },
        supportedOSVersion: String? = nil,
        now: @escaping () -> Date = { Date() },
        recorder: DiagnosticRecorder? = nil
    ) {
        self.bundle = bundle
        self.allowInsecureHTTP = allowInsecureHTTP ?? SourceURLPolicy.allowInsecureHTTP
        self.logProbe = logProbe
        self.signedBundleURL = signedBundleURL
        self.profileData = profileData
        self.archiveURL = archiveURL
        self.manifestEnvelope = manifestEnvelope
        if let supportedOSVersion {
            self.supportedOSVersion = supportedOSVersion
        } else {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            self.supportedOSVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }
        self.now = now
        self.recorder = recorder
    }

    func checks() -> [SecurityCheck] {
        let rows = [
            transportCheck(),
            signatureCheck(),
            profileCheck(),
            archiveCheck(),
            manifestCheck(),
            logCheck()
        ]
        // A failing validator is a diagnostic fact; "unsupported" is not a
        // failure and never becomes one. Report each check at most once per
        // service instance so a screen refresh cannot flood the journal.
        for row in rows where row.status == .failed {
            guard reportedFailures.insert(row.id).inserted, let recorder else { continue }
            let event = DiagnosticEvent.make(
                code: DiagnosticEventCode.securityFailure,
                severity: .error,
                category: .security,
                userMessage: "A security validation check failed.",
                developerDetail: row.detail,
                recoverySuggestion: "Review the failing check in Diagnostics Center and export a bundle if it persists.",
                metadata: ["check": row.id]
            )
            Task { await recorder.record(event) }
        }
        return rows
    }

    // MARK: - Individual checks

    private func transportCheck() -> SecurityCheck {
        let ats = bundle.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]
        if ats?["NSAllowsArbitraryLoads"] as? Bool == true {
            return SecurityCheck(
                id: "transport",
                title: .localized("Network transport"),
                status: .failed,
                detail: .localized("App Transport Security allows arbitrary plaintext loads.")
            )
        }
        if allowInsecureHTTP {
            return SecurityCheck(
                id: "transport",
                title: .localized("Network transport"),
                status: .warning,
                detail: .localized("Plain HTTP is enabled for local sources only; use HTTPS for every remote source.")
            )
        }
        return SecurityCheck(
            id: "transport",
            title: .localized("Network transport"),
            status: .passed,
            detail: .localized("HTTPS is required for remote sources; redirects cannot downgrade to HTTP.")
        )
    }

    private func signatureCheck() -> SecurityCheck {
        guard let url = signedBundleURL() else {
            return SecurityCheck(
                id: "signature",
                title: .localized("Bundle signature structure"),
                status: .unsupported,
                detail: .localized("No signed library app was available to inspect on this device.")
            )
        }
        let report = SignatureVerifier.verify(bundleAt: url, expectation: .alreadySigned)
        let status: SecurityCheckStatus
        switch report.verdict {
        case .valid: status = .passed
        case .invalid: status = .failed
        case .incomplete, .unsupported: status = report.verdict == .incomplete ? .unknown : .unsupported
        }
        return SecurityCheck(
            id: "signature",
            title: .localized("Bundle signature structure"),
            status: status,
            detail: report.summary
        )
    }

    private func profileCheck() -> SecurityCheck {
        guard let data = profileData() else {
            return SecurityCheck(
                id: "profile",
                title: .localized("Provisioning profile"),
                status: .unsupported,
                detail: .localized("No certificate profile was available to parse on this device.")
            )
        }
        do {
            let profile = try ProvisioningProfileParser.parse(data, now: now())
            return SecurityCheck(
                id: "profile",
                title: .localized("Provisioning profile"),
                status: .passed,
                detail: .localized("Apple CMS signature verified; profile expires %@.",
                                   arguments: profile.ExpirationDate.formatted(date: .abbreviated, time: .omitted))
            )
        } catch {
            return SecurityCheck(
                id: "profile",
                title: .localized("Provisioning profile"),
                status: .failed,
                detail: .localized("The stored profile could not be authenticated and parsed.")
            )
        }
    }

    private func archiveCheck() -> SecurityCheck {
        guard let url = archiveURL() else {
            return SecurityCheck(
                id: "archive",
                title: .localized("Archive safety"),
                status: .unsupported,
                detail: .localized("Select an IPA to run the path, symlink, duplicate and mode checks.")
            )
        }
        do {
            try ArchiveSafetyValidator.validate(url)
            return SecurityCheck(
                id: "archive",
                title: .localized("Archive safety"),
                status: .passed,
                detail: .localized("Archive metadata passed the extraction safety policy.")
            )
        } catch {
            return SecurityCheck(
                id: "archive",
                title: .localized("Archive safety"),
                status: .failed,
                detail: .localized("Archive metadata was rejected by the extraction safety policy.")
            )
        }
    }

    private func manifestCheck() -> SecurityCheck {
        let provisioning = ReleaseManifestTrustStore.inspect(bundle: bundle)
        switch provisioning {
        case .malformed:
            return SecurityCheck(
                id: "manifest",
                title: .localized("Release manifest trust"),
                status: .failed,
                detail: .localized("The bundled release-key configuration is malformed.")
            )
        case .unprovisioned:
            return SecurityCheck(
                id: "manifest",
                title: .localized("Release manifest trust"),
                status: .unsupported,
                detail: .localized("This build has no pinned release key, so signed manifests cannot be verified.")
            )
        case .provisioned(let keyIDs):
            guard let envelope = manifestEnvelope() else {
                return SecurityCheck(
                    id: "manifest",
                    title: .localized("Release manifest trust"),
                    status: .unsupported,
                    detail: .localized("A release key is provisioned, but no signed manifest was supplied to check.")
                )
            }
            guard let store = ReleaseManifestTrustStore.load(bundle: bundle) else {
                return SecurityCheck(
                    id: "manifest",
                    title: .localized("Release manifest trust"),
                    status: .failed,
                    detail: .localized("The pinned release key could not be loaded for verification.")
                )
            }
            do {
                let manifest = try store.verify(
                    envelopeData: envelope,
                    supportedOSVersion: supportedOSVersion,
                    now: now()
                )
                return SecurityCheck(
                    id: "manifest",
                    title: .localized("Release manifest trust"),
                    status: .passed,
                    detail: .localized("Ed25519 signature verified with key %@ for version %@.",
                                       arguments: keyIDs.first ?? "", manifest.version)
                )
            } catch {
                return SecurityCheck(
                    id: "manifest",
                    title: .localized("Release manifest trust"),
                    status: .failed,
                    detail: .localized("The signed release manifest failed verification.")
                )
            }
        }
    }

    private func logCheck() -> SecurityCheck {
        let probe = "security-diagnostic-probe-not-a-real-token"
        let output = logProbe()
        let passed = !output.contains(probe) && output.contains(LogRedaction.marker)
        return SecurityCheck(
            id: "logging",
            title: .localized("Diagnostic log redaction"),
            status: passed ? .passed : .failed,
            detail: passed
                ? .localized("A synthetic credential was masked by the log redaction rule.")
                : .localized("The log redaction rule did not mask its synthetic credential.")
        )
    }
}
