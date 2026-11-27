import Foundation

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
struct TaskSigningTrace: Codable, Equatable, Sendable {
	/// `SigningStage`s in the order the engine reported them, repeats included — it is a trace.
	var stages: [SigningStage] = []
	/// The stage that was in flight when the run stopped, which is where a failure or a
	/// cancellation belongs.
	var stoppedAt: SigningStage?
	/// Set only by `.signatureVerified`. Never inferred from the run succeeding.
	var verified: Bool?
	/// Bounded result of the verifier's own final pass, when one ran. A finished
	/// run without this value has no persisted signature report to show.
	var verificationReport: SigningVerificationReport?
	/// Absent while the run is in flight.
	var outcome: Outcome?

	enum Outcome: String, Codable, Equatable, Sendable {
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
		case verificationReport
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
		// A report written by a newer build that this build cannot decode is
		// treated as absent, not as a reason to discard the whole task history.
		do {
			verificationReport = try container.decodeIfPresent(SigningVerificationReport.self, forKey: .verificationReport)
		} catch {
			verificationReport = nil
		}
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

	mutating func recordVerification(_ report: SigningVerificationReport) {
		verified = true
		verificationReport = report
	}

	mutating func record(outcome: Outcome) {
		self.outcome = outcome
	}

	/// True when nothing was ever observed, so a caller can tell "no evidence" from "no stages".
	var isEmpty: Bool {
		stages.isEmpty && stoppedAt == nil && outcome == nil && verified == nil && verificationReport == nil
	}
}
