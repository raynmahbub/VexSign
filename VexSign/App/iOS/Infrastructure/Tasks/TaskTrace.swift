import Foundation
import CryptoKit
import IDeviceSwift

struct TaskContext: Codable, Equatable, Sendable {
    var appVersion: String?
    var appBuild: String?
    var installationMethod: String?
    var expectedBundleIdentifier: String?
    var handoffAt: Date?
    var lastReconciliationAt: Date?
    var monitoringActive: Bool?
    var certificateReference: String?
    var optionsFingerprint: String?
    var artifactID: String?
    var signingTaskID: String?
    var importTaskID: String?
    var confirmationReason: String?
    /// How many times the device was asked whether an install landed. A count only. Optional
    /// for the same reason as the trace below: history written before it existed must load.
    var verificationAttempts: Int?
    var errorCategory: String?
    var errorCode: Int?
    /// Optional, not defaulted: the synthesized `Decodable` only tolerates a missing key for an
    /// optional, and history written before this field existed has to keep loading.
    var signingTrace: TaskSigningTrace?
    /// Optional for backward compatibility. This dated observation is not a
    /// reason-string success flag or a statement about current installed state.
    var installedApplicationEvidence: InstalledApplicationEvidence?
    var expectedDeviceBinding: DeviceSessionBinding?
    var nativeAcknowledgedAt: Date?
    var installationPackageSHA256: String?

    func hasConfirmedInstallation(notAfter: Date) -> Bool {
        guard confirmationReason == "device-confirmed-installed",
              let identifier = expectedBundleIdentifier, let handoffAt, let nativeAcknowledgedAt,
              handoffAt.timeIntervalSince1970.isFinite, nativeAcknowledgedAt.timeIntervalSince1970.isFinite,
              notAfter.timeIntervalSince1970.isFinite, nativeAcknowledgedAt >= handoffAt, nativeAcknowledgedAt <= notAfter,
              let digest = installationPackageSHA256, DeviceSessionBinding.isDigest(digest) else { return false }
        let exactPairedDeviceEvidence = installedApplicationEvidence?.confirms(bundleIdentifier: identifier,
            version: appVersion, build: appBuild, binding: expectedDeviceBinding,
            notBefore: nativeAcknowledgedAt, notAfter: notAfter) == true
        return InstallCompletionEvidencePolicy.allowsInstalledOutcome(
            method: InstallationEvidenceMethod(code: installationMethod),
            hasExactPairedDeviceEvidence: exactPairedDeviceEvidence
        )
    }

    mutating func recordFailure(_ error: Error) {
        let error = error as NSError
        errorCode = error.code
        switch error.domain {
        case NSURLErrorDomain: errorCategory = "network"
        case NSCocoaErrorDomain: errorCategory = "filesystem"
        case NSOSStatusErrorDomain: errorCategory = "security"
        default: errorCategory = "operation"
        }
    }

    // MARK: Signing trace

    /// The trace, or an empty one. Never nil for a caller that only reads.
    var signing: TaskSigningTrace { signingTrace ?? TaskSigningTrace() }

    mutating func recordSigningStage(_ stage: SigningStage) {
        var trace = signing
        trace.record(stage)
        signingTrace = trace
    }

    mutating func recordSigningVerification() {
        var trace = signing
        trace.recordVerification()
        signingTrace = trace
    }

    mutating func recordSigningOutcome(_ outcome: TaskSigningTrace.Outcome) {
        var trace = signing
        trace.record(outcome: outcome)
        signingTrace = trace
    }

    var clientVersion: String = BuildIdentity.version
    var sourceCommit: String = BuildIdentity.commit

    init() {}

    private enum CodingKeys: String, CodingKey {
        case appVersion, appBuild, installationMethod, expectedBundleIdentifier
        case handoffAt, lastReconciliationAt, monitoringActive
        case certificateReference, optionsFingerprint, artifactID
        case signingTaskID, importTaskID, confirmationReason, verificationAttempts
        case errorCategory, errorCode, signingTrace
        case installedApplicationEvidence, expectedDeviceBinding, nativeAcknowledgedAt, installationPackageSHA256
        case clientVersion, sourceCommit
    }

    /// Decoded field by field, because a synthesized `Decodable` demands a key for every
    /// non-optional property even when that property has a default value.
    ///
    /// `clientVersion` and `sourceCommit` were added after the journal existed, so a history
    /// written before them lost `clientVersion` on read and threw — and a throw here takes the
    /// whole `[UnifiedTask.Snapshot]` array with it, which is the same loss the lenient trace
    /// decode above fixed one level down. An absent value stays empty, and the receipt renders
    /// empty as "unavailable" instead of attributing an old record to whichever build reads it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        appBuild = try container.decodeIfPresent(String.self, forKey: .appBuild)
        installationMethod = try container.decodeIfPresent(String.self, forKey: .installationMethod)
        expectedBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .expectedBundleIdentifier)
        handoffAt = try container.decodeIfPresent(Date.self, forKey: .handoffAt)
        lastReconciliationAt = try container.decodeIfPresent(Date.self, forKey: .lastReconciliationAt)
        monitoringActive = try container.decodeIfPresent(Bool.self, forKey: .monitoringActive)
        certificateReference = try container.decodeIfPresent(String.self, forKey: .certificateReference)
        optionsFingerprint = try container.decodeIfPresent(String.self, forKey: .optionsFingerprint)
        artifactID = try container.decodeIfPresent(String.self, forKey: .artifactID)
        signingTaskID = try container.decodeIfPresent(String.self, forKey: .signingTaskID)
        importTaskID = try container.decodeIfPresent(String.self, forKey: .importTaskID)
        confirmationReason = try container.decodeIfPresent(String.self, forKey: .confirmationReason)
        verificationAttempts = try container.decodeIfPresent(Int.self, forKey: .verificationAttempts)
        errorCategory = try container.decodeIfPresent(String.self, forKey: .errorCategory)
        errorCode = try container.decodeIfPresent(Int.self, forKey: .errorCode)
        signingTrace = try container.decodeIfPresent(TaskSigningTrace.self, forKey: .signingTrace)
        // A malformed optional proof must not discard unrelated task history.
        // Discarding it is fail-closed: hasConfirmedInstallation then returns false.
        installedApplicationEvidence = try? container.decodeIfPresent(InstalledApplicationEvidence.self, forKey: .installedApplicationEvidence) // try? ok: corrupt optional evidence is discarded and cannot promote history
        expectedDeviceBinding = try? container.decodeIfPresent(DeviceSessionBinding.self, forKey: .expectedDeviceBinding) // try? ok: corrupt optional evidence is discarded and cannot promote history
        nativeAcknowledgedAt = try? container.decodeIfPresent(Date.self, forKey: .nativeAcknowledgedAt) // try? ok: corrupt optional evidence is discarded and cannot promote history
        installationPackageSHA256 = try? container.decodeIfPresent(String.self, forKey: .installationPackageSHA256) // try? ok: corrupt optional evidence is discarded and cannot promote history
        clientVersion = try container.decodeIfPresent(String.self, forKey: .clientVersion) ?? ""
        sourceCommit = try container.decodeIfPresent(String.self, forKey: .sourceCommit) ?? ""
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func versionToken(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 64, raw.first?.isNumber == true,
              raw.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_+").contains($0) }) else { return nil }
        return raw
    }
}

struct TaskStageEntry: Codable, Equatable, Sendable {
    let phase: UnifiedTaskPhase
    let date: Date
}

enum BuildIdentity {
    static var version: String {
        let version = TaskContext.versionToken(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        let build = TaskContext.versionToken(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        return "\(version) (\(build))"
    }
    static func validatedVersion(_ raw: String?) -> String {
        guard let raw, raw.count <= 135,
              raw.range(of: #"^[0-9][a-zA-Z0-9._+\-]{0,63} \([0-9][a-zA-Z0-9._+\-]{0,63}\)$"#, options: .regularExpression) != nil else { return "unavailable" }
        return raw
    }

    static var commit: String {
        validatedCommit(Bundle.main.object(forInfoDictionaryKey: "VexSignSourceCommit") as? String)
    }
    static func validatedCommit(_ raw: String?) -> String {
        guard let raw, (7...40).contains(raw.count),
              raw.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { return "unavailable" }
        return raw.lowercased()
    }
}
