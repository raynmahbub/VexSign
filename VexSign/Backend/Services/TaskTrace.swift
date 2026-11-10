import Foundation
import CryptoKit

/// Deliberately allowlisted metadata: never store options payloads, certificate
/// contents, passwords, pairing records, raw URLs or filesystem paths here.
/// The signing engine's own execution trace, recorded as each stage is reported.
///
/// The signing sheet used to keep this in `@State`, so the workflow it displayed died with the
/// sheet: an app signed by another flow — batch, Update All, "Sign & Install" — showed every step
/// as "Not run", because the screen had no evidence and inventing some would be a lie. Storing the
/// trace on the task record makes the same evidence available afterwards, in Library details and
/// in the task receipt.
///
/// Only the engine's own stage names and verdicts are stored: no options, paths or identities.
struct TaskSigningTrace: Codable, Equatable {
	/// `SigningStage`s in the order the engine reported them, repeats included — it is a trace.
	var stages: [SigningStage] = []
	/// The stage that was in flight when the run stopped, which is where a failure or a
	/// cancellation belongs.
	var stoppedAt: SigningStage?
	/// Set only by `.signatureVerified`. Never inferred from the run succeeding.
	var verified: Bool?
	/// Absent while the run is in flight.
	var outcome: Outcome?

	enum Outcome: String, Codable, Equatable {
		case completed
		case failed
		case cancelled
	}

	/// Bounded so a pathological run cannot grow the persisted history without limit.
	private static let stageLimit = 32

	mutating func record(_ stage: SigningStage) {
		if stages.last != stage { stages.append(stage) }
		if stages.count > Self.stageLimit { stages.removeFirst(stages.count - Self.stageLimit) }
		stoppedAt = stage
	}

	mutating func recordVerification() {
		verified = true
	}

	mutating func record(outcome: Outcome) {
		self.outcome = outcome
	}

	/// True when nothing was ever observed, so a caller can tell "no evidence" from "no stages".
	var isEmpty: Bool { stages.isEmpty && stoppedAt == nil && outcome == nil && verified == nil }
}

struct TaskContext: Codable, Equatable {
    var appVersion: String?
    var appBuild: String?
    var installationMethod: String?
    var certificateReference: String?
    var optionsFingerprint: String?
    var artifactID: String?
    var signingTaskID: String?
    var importTaskID: String?
    var confirmationReason: String?
    var errorCategory: String?
    var errorCode: Int?
    /// Optional, not defaulted: the synthesized `Decodable` only tolerates a missing key for an
    /// optional, and history written before this field existed has to keep loading.
    var signingTrace: TaskSigningTrace?

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

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func versionToken(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 64, raw.first?.isNumber == true,
              raw.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_+").contains($0) }) else { return nil }
        return raw
    }
}

struct TaskStageEntry: Codable, Equatable {
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
