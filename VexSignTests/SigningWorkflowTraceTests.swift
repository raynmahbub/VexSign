//
//  SigningWorkflowTraceTests.swift
//  VexSignTests
//
//  Regression tests for the Signing workflow panel reporting "Not run" for every step.
//
//  Two defects produced that, and both are asserted here rather than described:
//
//    * the sheet derived "the run succeeded" from `_postSignAction != nil` — a property that
//      only exists to hand off when the log sheet happens to be open. On a normal successful run
//      it was nil, so the last step fell through to "Not run" at the exact moment signing worked;
//    * the trace lived in `@State`, so it died with the sheet, which the run dismisses on success.
//      An app signed by "Sign & Install", Update All or a batch job therefore had no evidence to
//      show at all, and every step read "Not run".
//
//  The fix records the engine's own stage events on the task record (`TaskSigningTrace`) and
//  rebuilds the panel from them. Nothing here manufactures a step: every completion traces back
//  to an event the signing engine actually reported.
//

import CoreData
import Foundation
import XCTest
@testable import VexSign

final class SigningWorkflowTraceTests: XCTestCase {
	// MARK: - No evidence

	func testEveryStepIsNotRunBeforeAnythingIsObserved() {
		let snapshot = SigningWorkflowSnapshot()
		XCTAssertTrue(snapshot.isEmpty)
		for step in SigningWorkspaceStep.allCases where step != .install {
			XCTAssertEqual(step.status(snapshot), .pending, "\(step) must read Not run with no evidence")
		}
		// Installation is a separate lifecycle, so it never reads "Not run" — it is not this
		// workflow's step to complete.
		XCTAssertEqual(SigningWorkspaceStep.install.status(snapshot), .separate)
	}

	func testAnEmptyTraceRestoresToEveryStepNotRun() {
		let snapshot = SigningWorkflowSnapshot(trace: TaskSigningTrace())
		XCTAssertTrue(snapshot.isEmpty)
		for step in SigningWorkspaceStep.allCases where step != .install {
			XCTAssertEqual(step.status(snapshot), .pending)
		}
	}

	func testAStepTheEngineNeverReportedStaysNotRun() {
		// Copying then straight to signing: the customization step was genuinely skipped.
		var trace = TaskSigningTrace()
		trace.record(.copying)
		trace.record(.signing)
		let snapshot = SigningWorkflowSnapshot(trace: trace, running: true)
		XCTAssertEqual(SigningWorkspaceStep.customize.status(snapshot), .pending)
		XCTAssertEqual(SigningWorkspaceStep.verify.status(snapshot), .pending)
	}

	// MARK: - Active step

	func testTheActiveStepIsTheOneTheEngineIsReporting() {
		var trace = TaskSigningTrace()
		trace.record(.copying)
		let snapshot = SigningWorkflowSnapshot(trace: trace, running: true)
		XCTAssertEqual(SigningWorkspaceStep.prepare.status(snapshot), .active)
		for step in [SigningWorkspaceStep.customize, .sign, .verify] {
			XCTAssertEqual(step.status(snapshot), .pending)
		}
	}

	func testStepsTheRunMovedPastStayCompleted() {
		var trace = TaskSigningTrace()
		for stage in [SigningStage.copying, .modifying, .thinning, .signing] { trace.record(stage) }
		let snapshot = SigningWorkflowSnapshot(trace: trace, running: true)
		XCTAssertEqual(SigningWorkspaceStep.prepare.status(snapshot), .completed)
		XCTAssertEqual(SigningWorkspaceStep.customize.status(snapshot), .completed)
		XCTAssertEqual(SigningWorkspaceStep.sign.status(snapshot), .active)
		XCTAssertEqual(SigningWorkspaceStep.verify.status(snapshot), .pending)
	}

	// MARK: - Terminal outcomes

	func testAFailedRunMarksTheStepItActuallyStoppedAt() {
		var trace = TaskSigningTrace()
		for stage in [SigningStage.copying, .modifying, .signing] { trace.record(stage) }
		trace.record(outcome: .failed)
		let snapshot = SigningWorkflowSnapshot(trace: trace)
		XCTAssertEqual(snapshot.failed, true)
		XCTAssertEqual(SigningWorkspaceStep.sign.status(snapshot), .failed)
		XCTAssertEqual(SigningWorkspaceStep.prepare.status(snapshot), .completed)
		XCTAssertEqual(SigningWorkspaceStep.customize.status(snapshot), .completed)
		XCTAssertEqual(SigningWorkspaceStep.verify.status(snapshot), .pending)
	}

	func testACancelledRunMarksTheStepItActuallyStoppedAt() {
		var trace = TaskSigningTrace()
		for stage in [SigningStage.copying, .thinning] { trace.record(stage) }
		trace.record(outcome: .cancelled)
		let snapshot = SigningWorkflowSnapshot(trace: trace)
		XCTAssertEqual(snapshot.cancelled, true)
		XCTAssertEqual(SigningWorkspaceStep.customize.status(snapshot), .cancelled)
		XCTAssertEqual(SigningWorkspaceStep.prepare.status(snapshot), .completed)
		XCTAssertEqual(SigningWorkspaceStep.sign.status(snapshot), .pending)
		XCTAssertEqual(SigningWorkspaceStep.verify.status(snapshot), .pending)
	}

	func testAFailureAfterVerificationLandsOnVerifyNotOnAnEarlierStep() {
		// The signature verified, then registering the artifact failed. The terminal outcome
		// outranks the earlier completion evidence, because that is where the run stopped.
		var trace = TaskSigningTrace()
		for stage in [SigningStage.copying, .signing, .verifying, .registering] { trace.record(stage) }
		trace.recordVerification()
		trace.record(outcome: .failed)
		let snapshot = SigningWorkflowSnapshot(trace: trace)
		XCTAssertEqual(snapshot.verified, true)
		XCTAssertEqual(SigningWorkspaceStep.verify.status(snapshot), .failed)
		XCTAssertEqual(SigningWorkspaceStep.sign.status(snapshot), .completed)
	}

	// MARK: - Verification evidence

	func testReachingTheVerifyStepDoesNotCompleteIt() {
		var trace = TaskSigningTrace()
		for stage in [SigningStage.copying, .modifying, .signing, .verifying] { trace.record(stage) }
		let snapshot = SigningWorkflowSnapshot(trace: trace, running: true)
		XCTAssertEqual(snapshot.verified, false)
		XCTAssertEqual(SigningWorkspaceStep.verify.status(snapshot), .active)
	}

	func testVerifyStaysNotRunWhenTheRunSucceedsWithoutEverVerifying() {
		// "Modify without signing" registers an artifact without verifying a signature, and it
		// still reaches `.registering`. Inferring verification from success — or from reaching a
		// late stage — would report a check that never ran.
		var trace = TaskSigningTrace()
		for stage in [SigningStage.copying, .modifying, .registering] { trace.record(stage) }
		trace.record(outcome: .completed)
		let snapshot = SigningWorkflowSnapshot(trace: trace)
		XCTAssertTrue(snapshot.succeeded)
		XCTAssertEqual(snapshot.verified, false)
		XCTAssertEqual(SigningWorkspaceStep.prepare.status(snapshot), .completed)
		XCTAssertEqual(SigningWorkspaceStep.customize.status(snapshot), .completed)
		XCTAssertEqual(SigningWorkspaceStep.sign.status(snapshot), .pending)
		XCTAssertEqual(SigningWorkspaceStep.verify.status(snapshot), .pending)
	}

	func testVerifyCompletesOnlyOnTheEnginesOwnVerification() {
		var trace = TaskSigningTrace()
		for stage in [SigningStage.copying, .signing, .verifying] { trace.record(stage) }
		trace.recordVerification()
		let snapshot = SigningWorkflowSnapshot(trace: trace, running: true)
		XCTAssertEqual(snapshot.verified, true)
		XCTAssertEqual(SigningWorkspaceStep.verify.status(snapshot), .completed)
	}

	// MARK: - Installation is separate

	func testASuccessfulRunCompletesEverySigningStepButNeverInstall() {
		var trace = TaskSigningTrace()
		for stage in SigningStage.allCases { trace.record(stage) }
		trace.recordVerification()
		trace.record(outcome: .completed)
		let snapshot = SigningWorkflowSnapshot(trace: trace)
		for step in [SigningWorkspaceStep.prepare, .customize, .sign, .verify] {
			XCTAssertEqual(step.status(snapshot), .completed, "\(step) ran and was reported")
		}
		XCTAssertEqual(SigningWorkspaceStep.install.status(snapshot), .separate)
	}

	func testInstallIsSeparateEvenWhileSigningIsStillRunning() {
		var trace = TaskSigningTrace()
		trace.record(.copying)
		let snapshot = SigningWorkflowSnapshot(trace: trace, running: true)
		XCTAssertEqual(SigningWorkspaceStep.install.status(snapshot), .separate)
	}

	func testAFailedRunNeverClaimsInstallationEither() {
		var trace = TaskSigningTrace()
		trace.record(.signing)
		trace.record(outcome: .failed)
		let snapshot = SigningWorkflowSnapshot(trace: trace)
		XCTAssertEqual(SigningWorkspaceStep.install.status(snapshot), .separate)
	}

	// MARK: - The legacy flags the sheet used to pass

	func testTheFlagBasedEntryPointStillReadsOverallSuccessAsVerification() {
		// Kept so the sheet's live path and the older call signature agree: a run can only finish
		// successfully when `_verifySignedBundle` accepted the bundle.
		let observed: Set<SigningStage> = [.copying, .signing, .verifying]
		XCTAssertEqual(
			SigningWorkspaceStep.verify.status(reached: observed, current: .verifying,
				running: false, succeeded: true, failed: false, cancelled: false),
			.completed
		)
		XCTAssertEqual(
			SigningWorkspaceStep.verify.status(reached: observed, current: .verifying,
				running: false, succeeded: false, failed: false, cancelled: false),
			.pending,
			"A run that has not finished must not complete Verify"
		)
	}

	// MARK: - Recording

	func testTaskContextRecordsTheTraceAsTheEngineReportsIt() {
		var context = TaskContext()
		XCTAssertNil(context.signingTrace, "No trace exists before the engine reports anything")
		XCTAssertTrue(context.signing.isEmpty)

		context.recordSigningStage(.copying)
		context.recordSigningStage(.modifying)
		context.recordSigningStage(.signing)
		context.recordSigningVerification()
		context.recordSigningStage(.verifying)
		context.recordSigningOutcome(.completed)

		let trace = context.signing
		XCTAssertEqual(trace.stages, [.copying, .modifying, .signing, .verifying])
		XCTAssertEqual(trace.stoppedAt, .verifying)
		XCTAssertEqual(trace.verified, true)
		XCTAssertEqual(trace.outcome, .completed)
	}

	func testRepeatedStageReportsDoNotDuplicateTheTrace() {
		var trace = TaskSigningTrace()
		trace.record(.copying)
		trace.record(.copying)
		trace.record(.modifying)
		XCTAssertEqual(trace.stages, [.copying, .modifying])
		XCTAssertEqual(trace.stoppedAt, .modifying)
	}

	func testTheTraceIsBoundedSoPersistedHistoryCannotGrowWithoutLimit() {
		var trace = TaskSigningTrace()
		for index in 0..<200 { trace.record(index.isMultiple(of: 2) ? .copying : .signing) }
		XCTAssertLessThanOrEqual(trace.stages.count, 32)
		XCTAssertEqual(trace.stages.last, .signing)
		XCTAssertEqual(trace.stoppedAt, .signing)
	}

	// MARK: - Survival

	func testTheTraceSurvivesTaskHistorySerialization() throws {
		var context = TaskContext()
		for stage in SigningStage.allCases { context.recordSigningStage(stage) }
		context.recordSigningVerification()
		context.recordSigningOutcome(.completed)

		let task = UnifiedTask(kind: .sign, title: "Fixture App", phase: .signing, subjectID: "app-1")
		task.context = context

		let data = try JSONEncoder().encode(task.snapshot)
		let restored = try JSONDecoder().decode(UnifiedTask.Snapshot.self, from: data)
		let trace = try XCTUnwrap(UnifiedTask.from(restored).context?.signingTrace)

		XCTAssertEqual(trace.stages, SigningStage.allCases)
		XCTAssertEqual(trace.verified, true)
		XCTAssertEqual(trace.outcome, .completed)

		let snapshot = SigningWorkflowSnapshot(trace: trace)
		for step in [SigningWorkspaceStep.prepare, .customize, .sign, .verify] {
			XCTAssertEqual(step.status(snapshot), .completed)
		}
		XCTAssertEqual(SigningWorkspaceStep.install.status(snapshot), .separate)
	}

	func testContextWrittenBeforeTheTraceExistedStillDecodes() throws {
		// Task history on disk predates `signingTrace`. A non-optional field would have made
		// every stored task undecodable and the journal would have reported the whole history as
		// unreadable — which is why the trace is optional.
		let json = #"{"appVersion":"1.0","clientVersion":"1.0 (1)","sourceCommit":"0000000"}"#
		let context = try JSONDecoder().decode(TaskContext.self, from: Data(json.utf8))
		XCTAssertNil(context.signingTrace)
		XCTAssertTrue(context.signing.isEmpty)
		XCTAssertEqual(context.appVersion, "1.0")
	}

	@MainActor
	func testTheCenterKeepsTheTraceAfterTheRunFinishesAndLeavesTheActiveList() {
		let subject = "signing-trace-\(UUID().uuidString)"
		let task = UnifiedTaskCenter.shared.begin(kind: .sign, title: "Fixture App", phase: .signing, subjectID: subject)
		var context = TaskContext()
		for stage in SigningStage.allCases { context.recordSigningStage(stage) }
		context.recordSigningVerification()
		context.recordSigningOutcome(.completed)
		task.context = context

		XCTAssertEqual(UnifiedTaskCenter.shared.latestSigningTask(subjectID: subject)?.id, task.id)

		// Finishing moves the record to history — the moment the signing sheet is dismissed and
		// its `@State` is gone. The trace has to still be answerable afterwards.
		UnifiedTaskCenter.shared.transition(task, to: .signed, progress: 1)
		UnifiedTaskCenter.shared.transition(task, to: .completed, progress: 1)
		XCTAssertFalse(UnifiedTaskCenter.shared.tasks.contains { $0.id == task.id })
		XCTAssertEqual(UnifiedTaskCenter.shared.signingTrace(subjectID: subject)?.stages, SigningStage.allCases)
		XCTAssertEqual(UnifiedTaskCenter.shared.signingTrace(subjectID: subject)?.outcome, .completed)
	}

	@MainActor
	func testAnAppThatWasNeverSignedHasNoWorkflowToShow() {
		let bare = "never-signed-\(UUID().uuidString)"
		let task = UnifiedTaskCenter.shared.begin(kind: .sign, title: "Fixture App", phase: .signing, subjectID: bare)
		defer { UnifiedTaskCenter.shared.transition(task, to: .cancelled) }

		XCTAssertNil(
			UnifiedTaskCenter.shared.signingTrace(subjectID: bare),
			"A run that reported no stages has no evidence, and must not invent a workflow"
		)
		XCTAssertNil(UnifiedTaskCenter.shared.signingTrace(subjectID: "no-such-app"))
		XCTAssertNil(UnifiedTaskCenter.shared.latestSigningTask(subjectID: nil))
		XCTAssertNil(UnifiedTaskCenter.shared.latestSigningTask(subjectID: ""))
	}

	// MARK: - The engine reports verification as its own event

	func testSignatureVerificationIsANonTerminalEventOfItsOwn() {
		XCTAssertFalse(SigningEvent.signatureVerified.isTerminal,
			"Verification is progress, so it must reach subscribers instead of ending the run")
		XCTAssertFalse(SigningEvent.stage(.verifying).isTerminal)
		XCTAssertFalse(SigningEvent.compatibilityRemoved(["Widget.appex"]).isTerminal)
		XCTAssertTrue(SigningEvent.cancelled.isTerminal)
		XCTAssertTrue(SigningEvent.failed(NSError(domain: "SigningWorkflowTraceTests", code: 1)).isTerminal)
	}

	/// Delivery, not just emission: the service hands every non-terminal event to its main-actor
	/// subscriber in the order the engine produced it, verification included. A stage reported off
	/// the main actor and dropped there is how a panel ends up reading "Not run" after a run that
	/// worked.
	@MainActor
	func testVerificationAndStagesReachTheMainActorSubscriberInOrder() async throws {
		let signed = _signed()
		let work = _VerificationWork(signed: signed)
		let service = SigningService(work: work)
		let request = SigningRequest(id: "verification-\(UUID().uuidString)", app: signed,
			options: Options.defaultOptions, icon: nil, certificate: nil)

		var events: [SigningEvent] = []
		var deliveredOffMain = 0
		XCTAssertNotNil(service.sign(request) { event in
			if !Thread.isMainThread { deliveredOffMain += 1 }
			events.append(event)
		})

		let deadline = Date().addingTimeInterval(5)
		while !events.contains(where: { $0.isTerminal }), Date() < deadline {
			try await Task.sleep(nanoseconds: 20_000_000)
		}
		XCTAssertTrue(events.contains(where: { $0.isTerminal }), "The run must reach a terminal event")
		XCTAssertEqual(deliveredOffMain, 0,
			"Stages are produced off the main actor; a subscriber that mutates view state must not receive them there")

		XCTAssertEqual(_stages(events), [.copying, .signing, .verifying, .registering])
		XCTAssertEqual(_verificationCount(events), 1)
		let verificationAt = try XCTUnwrap(events.firstIndex {
			guard case .signatureVerified = $0 else { return false }
			return true
		})
		let verifyingAt = try XCTUnwrap(_stages(events).firstIndex(of: .verifying))
		XCTAssertGreaterThan(verificationAt, verifyingAt,
			"Verification is reported after the verify stage began, never before")
		XCTAssertEqual(_terminalCount(events), 1)
	}

	/// The whole trace, rebuilt from the events a subscriber actually received — which is what the
	/// sheet records on the task, and what the panel is drawn from afterwards.
	@MainActor
	func testTheRecordedTraceMatchesWhatTheSubscriberReceived() async throws {
		let signed = _signed()
		let service = SigningService(work: _VerificationWork(signed: signed))
		let request = SigningRequest(id: "trace-\(UUID().uuidString)", app: signed,
			options: Options.defaultOptions, icon: nil, certificate: nil)

		var context = TaskContext()
		var events: [SigningEvent] = []
		service.sign(request) { event in
			events.append(event)
			switch event {
			case .stage(let stage): context.recordSigningStage(stage)
			case .signatureVerified: context.recordSigningVerification()
			case .finished: context.recordSigningOutcome(.completed)
			case .cancelled: context.recordSigningOutcome(.cancelled)
			case .failed: context.recordSigningOutcome(.failed)
			case .compatibilityRemoved: break
			}
		}

		let deadline = Date().addingTimeInterval(5)
		while !events.contains(where: { $0.isTerminal }), Date() < deadline {
			try await Task.sleep(nanoseconds: 20_000_000)
		}

		let trace = try XCTUnwrap(context.signingTrace)
		XCTAssertEqual(trace.stages, [.copying, .signing, .verifying, .registering])
		XCTAssertEqual(trace.verified, true)
		XCTAssertEqual(trace.outcome, .completed)

		let snapshot = SigningWorkflowSnapshot(trace: trace)
		for step in [SigningWorkspaceStep.prepare, .sign, .verify] {
			XCTAssertEqual(step.status(snapshot), .completed)
		}
		// This run reports copying, signing, verifying and registering - never `.modifying`, which is
		// the only stage that reaches Customize. Production emits that stage through
		// SigningHandler.onStage, so a plain sign that injects nothing legitimately never gets there.
		// Completion is on evidence only, so Customize must not be reported as having run.
		XCTAssertEqual(SigningWorkspaceStep.customize.status(snapshot), .pending,
			"A stage the engine never reported must not be shown as completed")
		XCTAssertEqual(SigningWorkspaceStep.install.status(snapshot), .separate)
	}

	// MARK: - Fixtures

	/// `Storage` is queue-bound, so the store is created on the main actor and thrown away after
	/// each test — the same fixture discipline `SigningServiceTests` uses.
	private nonisolated(unsafe) static var storage: Storage?

	override func tearDown() {
		Self.storage = nil
		super.tearDown()
	}

	@MainActor
	private func _signed(_ name: String = "Fixture") -> Signed {
		let storage = Self.storage ?? Storage(inMemory: true)
		Self.storage = storage
		let signed = Signed(context: storage.context)
		signed.name = name
		signed.uuid = UUID().uuidString
		return signed
	}

	private func _stages(_ events: [SigningEvent]) -> [SigningStage] {
		events.compactMap {
			guard case .stage(let stage) = $0 else { return nil }
			return stage
		}
	}

	private func _verificationCount(_ events: [SigningEvent]) -> Int {
		events.reduce(0) { count, event in
			guard case .signatureVerified = event else { return count }
			return count + 1
		}
	}

	private func _terminalCount(_ events: [SigningEvent]) -> Int {
		events.filter(\.isTerminal).count
	}
}

// MARK: - Helpers

/// Reports stages, then verification, then finishes — the order the real handler produces, with
/// the stage callbacks coming from off the main actor the way the pipeline's do.
private final class _VerificationWork: SigningWork {
	private let signed: Signed

	init(signed: Signed) { self.signed = signed }

	func run(_ request: SigningRequest, reporting: @escaping (SigningEvent) -> Void) async -> Result<Signed, Error> {
		await Task.detached(priority: .userInitiated) {
			reporting(.stage(.copying))
			reporting(.stage(.signing))
			reporting(.stage(.verifying))
			reporting(.signatureVerified)
			reporting(.stage(.registering))
		}.value
		return .success(signed)
	}

	// MARK: - Observed stages

	func testOnlyReportedStagesAreListedUnderTheirStep() {
		let snapshot = SigningWorkflowSnapshot(reached: [.copying, .modifying, .signing, .verifying], current: .verifying, running: true)

		XCTAssertEqual(snapshot.observedStages(in: .prepare), [.copying])
		XCTAssertEqual(snapshot.observedStages(in: .customize), [.modifying], "Thinning and injecting were not reported, so they are not listed")
		XCTAssertEqual(snapshot.observedStages(in: .sign), [.signing])
		XCTAssertEqual(snapshot.observedStages(in: .verify), [.verifying])
	}

	func testObservedStagesFollowRunOrderAndInstallNeverHasAny() {
		let snapshot = SigningWorkflowSnapshot(reached: Set(SigningStage.allCases), succeeded: true, verified: true)

		XCTAssertEqual(snapshot.observedStages(in: .customize), [.modifying, .thinning, .injecting])
		XCTAssertEqual(snapshot.observedStages(in: .verify), [.verifying, .registering])
		XCTAssertEqual(snapshot.observedStages(in: .install), [], "Signing reports nothing about installation")
		XCTAssertEqual(SigningWorkflowSnapshot().observedStages(in: .prepare), [])
	}
}
