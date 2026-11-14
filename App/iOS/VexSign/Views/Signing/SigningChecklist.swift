//
//  SigningChecklist.swift
//  VexSign
//
//  The ten steps of one signing run, each with the evidence it rests on.
//
//  The five-step workflow groups the engine's stages; this lists them one by one and adds
//  the two checks that happen before the engine starts. No step is ever marked from elapsed
//  time or from the run "probably" having done it:
//
//    1  Identity   — `SigningIdentityPolicy`, evaluated on the selected certificate
//    2  Preflight  — the result of `PreflightChecks`, once it has run on this screen
//    3–9           — the seven stages the engine reports, individually
//    10 Install    — never completed by signing; it has its own lifecycle
//
//  A stage the run did not report is "Not run" while it could still happen and "Skipped"
//  once the run has provably moved past it.
//

import SwiftUI
import NimbleExtensions

// MARK: - Model

enum SigningChecklistStep: Int, CaseIterable, Identifiable, Sendable {
	case identity, preflight, copy, modify, thin, inject, sign, verify, register, install

	var id: Int { rawValue }

	/// The engine stage behind this step; nil for the checks before the run and for install.
	var stage: SigningStage? {
		switch self {
		case .identity, .preflight, .install: nil
		case .copy: .copying
		case .modify: .modifying
		case .thin: .thinning
		case .inject: .injecting
		case .sign: .signing
		case .verify: .verifying
		case .register: .registering
		}
	}

	var title: String {
		switch self {
		case .identity: .localized("Check the certificate")
		case .preflight: .localized("Review the setup")
		case .install: .localized("Install")
		case .copy, .modify, .thin, .inject, .sign, .verify, .register:
			// The engine's own wording, so the checklist and the progress line agree.
			stage?.title ?? ""
		}
	}

	enum Status: Equatable, Sendable {
		case pending, active, completed, failed, cancelled, skipped, notNeeded, separate

		var title: String {
			switch self {
			case .pending: .localized("Not run")
			case .active: .localized("In progress")
			case .completed: .localized("Completed")
			case .failed: .localized("Failed")
			case .cancelled: .localized("Cancelled")
			case .skipped: .localized("Skipped")
			case .notNeeded: .localized("Not needed")
			case .separate: .localized("Separate installation step")
			}
		}

		var icon: String {
			switch self {
			case .pending: "circle"
			case .active: "circle.inset.filled"
			case .completed: "checkmark.circle"
			case .failed: "exclamationmark.circle"
			case .cancelled: "stop.circle"
			case .skipped, .notNeeded: "minus.circle"
			case .separate: "arrow.up.forward.app"
			}
		}
	}
}

/// What is known about one run and the two checks before it.
struct SigningChecklistEvidence: Equatable {
	/// The outcome of a check made before the engine starts.
	enum Check: Equatable {
		/// The check has not been made.
		case notRun
		case passed
		/// Passed with things worth reading; carries how many.
		case passedWithWarnings(Int)
		/// Carries the sentence that explains the failure.
		case failed(String)
		/// The run does not use what this checks (a modify-only run has no certificate).
		case notNeeded
	}

	var identity: Check = .notRun
	var preflight: Check = .notRun
	var run = SigningWorkflowSnapshot()

	struct Row: Equatable, Identifiable {
		let step: SigningChecklistStep
		let status: SigningChecklistStep.Status
		/// The reason behind a failure or a warning count, when there is one.
		let detail: String?

		var id: Int { step.rawValue }
	}

	/// All ten rows, in order.
	var rows: [Row] {
		SigningChecklistStep.allCases.map { step in
			let (status, detail) = resolve(step)
			return Row(step: step, status: status, detail: detail)
		}
	}

	func status(of step: SigningChecklistStep) -> SigningChecklistStep.Status { resolve(step).0 }

	private func resolve(_ step: SigningChecklistStep) -> (SigningChecklistStep.Status, String?) {
		switch step {
		case .identity: return Self.resolve(identity)
		case .preflight: return Self.resolve(preflight)
		// Signing can start an installation. It can never confirm one.
		case .install: return (.separate, nil)
		case .copy, .modify, .thin, .inject, .sign, .verify, .register:
			guard let stage = step.stage else { return (.pending, nil) }
			return (Self.status(of: stage, in: run), nil)
		}
	}

	private static func resolve(_ check: Check) -> (SigningChecklistStep.Status, String?) {
		switch check {
		case .notRun: (.pending, nil)
		case .passed: (.completed, nil)
		case .passedWithWarnings(let count): (.completed, String.localized("%lld to review", arguments: count))
		case .failed(let reason): (.failed, reason)
		case .notNeeded: (.notNeeded, nil)
		}
	}

	/// One engine stage, from what the run reported and nothing else.
	static func status(of stage: SigningStage, in run: SigningWorkflowSnapshot) -> SigningChecklistStep.Status {
		let order = SigningStage.allCases
		guard let position = order.firstIndex(of: stage) else { return .pending }
		let movedPast = run.reached.contains { later in
			(order.firstIndex(of: later) ?? -1) > position
		}

		guard run.reached.contains(stage) else {
			// Verification is never "skipped": a run that did not report it did not verify.
			if stage == .verifying { return .pending }
			return (movedPast || run.succeeded) ? .skipped : .pending
		}

		if run.current == stage {
			// The engine's verdict is a fact about the bundle; it stands while the run goes on.
			if stage == .verifying, run.verified, !run.failed, !run.cancelled { return .completed }
			if run.running { return .active }
			if run.failed { return .failed }
			if run.cancelled { return .cancelled }
		}

		if stage == .verifying { return run.verified ? .completed : .pending }
		return (movedPast || run.succeeded) ? .completed : .pending
	}
}

// MARK: - View

struct SigningChecklistView: View {
	let evidence: SigningChecklistEvidence
	var identifier: String = A11y.Signing.workflow

	private func color(_ status: SigningChecklistStep.Status) -> Color {
		switch status {
		case .failed: .red
		case .completed: .green
		case .active: Theme.tint
		case .pending, .cancelled, .skipped, .notNeeded, .separate: .secondary
		}
	}

	var body: some View {
		DisclosureGroup(String.localized("Signing steps")) {
			VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
				ForEach(evidence.rows) { row in
					HStack(alignment: .top, spacing: Theme.Spacing.medium) {
						Image(systemName: row.status.icon)
							.foregroundStyle(color(row.status))
							.accessibilityHidden(true)
						VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
							Text(row.step.title).font(.subheadline.weight(.semibold))
							Text(row.status.title).font(.caption).foregroundStyle(.secondary)
							if let detail = row.detail {
								Text(detail).font(.caption2).foregroundStyle(.secondary)
							}
						}
					}
					.accessibilityElement(children: .combine)
				}
				Text(.localized("Only observed signing stages are marked complete. Installation is tracked separately; signing does not confirm that the app is installed."))
					.font(.caption).foregroundStyle(.secondary)
			}
			.padding(.vertical, Theme.Spacing.small)
		}
		.accessibilityIdentifier(identifier)
	}
}
