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

	private enum CodingKeys: String, CodingKey {
		case stages
		case stoppedAt
		case verified
		case outcome
	}

	init() {}

	/// Decodes stages by their raw value instead of as an enum.
	///
	/// A trace is *persisted*, and `SigningStage`'s raw values are the on-disk form. Decoding
	/// `[SigningStage]` directly meant that a single raw value this build does not know — a stage
	/// added by a newer build, or read back after a downgrade — threw, and the throw propagated
	/// out of `TaskContext` into the whole `[UnifiedTask.Snapshot]` decode. The journal then
	/// treated the entire history file as corrupt and started empty: up to 200 finished tasks
	/// lost because one stage name was unfamiliar.
	///
	/// The rest of the record already works this way (`UnifiedTask.Snapshot` keeps `kind`,
	/// `phase` and `failureStage` as `String` and falls back on read), so this closes the one
	/// field that was still strict. Unknown stages are dropped rather than guessed, and the
	/// caller can still tell "no evidence" from "no stages" through `isEmpty`.
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		stages = (try container.decodeIfPresent([String].self, forKey: .stages) ?? [])
			.compactMap(SigningStage.init(rawValue:))
		stoppedAt = try container.decodeIfPresent(String.self, forKey: .stoppedAt)
			.flatMap(SigningStage.init(rawValue:))
		verified = try container.decodeIfPresent(Bool.self, forKey: .verified)
		outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
			.flatMap(Outcome.init(rawValue:))
	}

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

    // Written out so `init(from:)` below can read the two build fields leniently.
    private enum CodingKeys: String, CodingKey {
        case appVersion
        case appBuild
        case installationMethod
        case expectedBundleIdentifier
        case handoffAt
        case lastReconciliationAt
        case monitoringActive
        case certificateReference
        case optionsFingerprint
        case artifactID
        case signingTaskID
        case importTaskID
        case confirmationReason
        case verificationAttempts
        case errorCategory
        case errorCode
        case signingTrace
        case clientVersion
        case sourceCommit
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

extension TaskContext {
    /// History written before the build fields existed has neither key. The synthesized
    /// decoder treats a defaulted, non-optional property as required, so one such record
    /// failed the whole history array. A record that does not say which build wrote it is
    /// read as "unknown", never as this build.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
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
        clientVersion = try container.decodeIfPresent(String.self, forKey: .clientVersion) ?? "unknown"
        sourceCommit = try container.decodeIfPresent(String.self, forKey: .sourceCommit)
            ?? BuildIdentity.validatedCommit(nil)
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
