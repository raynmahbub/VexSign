//
//  InstallStatusPresentation.swift
//  VexSign
//
//  What the install card says, decided in one pure place.
//
//  The transport and the install lifecycle are two different clocks. The transport is
//  `InstallerStatusViewModel.InstallerStatus`: it describes VexSign's local server and the
//  payload transfer. The lifecycle is `InstallConfirmation.Phase`: it describes what installd and
//  the device are actually doing. They disagree for a real stretch of every OTA install — the
//  server reports `.ready` the instant it can serve, while iOS shows its own confirmation prompt,
//  and the transport has nothing to report again until the user answers.
//
//  The card used to resolve that by ignoring the lifecycle unless the transport happened to be
//  `.installing`:
//
//      guard case .installing = viewModel.status else { return viewModel.statusLabel }
//
//  so an install the user was being asked to confirm read "Ready" — the server's state, not the
//  installation's. The same guard hid verification from every status except the one the OTA path
//  passes through, and the accessibility label on the progress ring kept saying "Installing"
//  while the screen was still packaging.
//
//  The rule now: a terminal transport answer wins, the lifecycle outranks a transport status that
//  has not caught up, and the transport is the fallback for the stretches the lifecycle cannot
//  describe on its own (packaging and payload transfer, before any progress exists).
//

import Foundation
import IDeviceSwift
import NimbleExtensions

// MARK: - Presentation

/// The one line, icon and (optional) number an install card shows for one moment of an install.
struct InstallStatusPresentation: Equatable {
	let label: String
	let systemImage: String
	/// Only ever a number the device or the transport actually reported; nil otherwise.
	let percentage: Int?

	/// Resolves what to show from the transport status and the install lifecycle.
	///
	/// `verificationAttempt` counts the device checks; `overallProgress` and `isCompleted` are passed
	/// through to the existing percentage rule so the card keeps its "never invent a percentage"
	/// guarantee.
	static func resolve(
		transport: InstallerStatusViewModel.InstallerStatus,
		phase: InstallConfirmation.Phase,
		verificationAttempt: Int = 0,
		overallProgress: Double = 0,
		isCompleted: Bool = false
	) -> InstallStatusPresentation {
		let percentage = InstallerStatusViewModel.displayedPercentage(
			phase: phase,
			overall: overallProgress,
			isCompleted: isCompleted
		)

		switch transport {
		case .broken, .completed:
			// A failure must never be dressed as progress, and a completion is terminal in both
			// directions: `.completed(.success)` is published only for an outcome the device
			// proved, and `.completed(.failure)` is still a failure. Nothing later in the
			// lifecycle may overwrite either.
			return InstallStatusPresentation(
				label: InstallerStatusViewModel.label(for: transport),
				systemImage: InstallerStatusViewModel.image(for: transport),
				percentage: percentage
			)
		case .none, .ready, .sendingManifest, .sendingPayload, .installing:
			break
		}

		switch phase {
		case .verifying:
			// The device is being asked, whatever the transport last said. Showing "Installing"
			// here claims progress that installd has already stopped reporting.
			return InstallStatusPresentation(
				label: InstallVerificationPolicy.statusLabel(attempt: verificationAttempt),
				systemImage: "checkmark.shield",
				percentage: percentage
			)

		case .downloading:
			// installd is reporting a counter, which is the installation itself — even while the
			// transport is still serving the payload that counter belongs to.
			return InstallStatusPresentation(
				label: .localized("Installing"),
				systemImage: "square.and.arrow.down",
				percentage: percentage
			)

		case .waitingForStart:
			// `.ready` means VexSign can serve the install; iOS shows its prompt immediately
			// afterwards. Until that prompt is answered the transport has nothing more to say,
			// and "Ready" would describe the server rather than the installation.
			if case .ready = transport {
				return InstallStatusPresentation(
					label: .localized("Waiting for iOS installation"),
					systemImage: "hourglass",
					percentage: percentage
				)
			}
			return InstallStatusPresentation(
				label: InstallerStatusViewModel.label(for: transport),
				systemImage: InstallerStatusViewModel.image(for: transport),
				percentage: percentage
			)

		case .finished(let verdict):
			// The card is on its way out, but the moment before it goes must still be true: a
			// timeout is not "Ready", and an unconfirmed install is not an installed one.
			return InstallStatusPresentation(
				label: verdict.cardLabel,
				systemImage: verdict.cardImage,
				percentage: percentage
			)
		}
	}
}

// MARK: - Verdict wording

private extension InstallConfirmation.Verdict {
	/// Short label for the card; the full explanation stays in `message` and the task report.
	var cardLabel: String {
		switch self {
		case .installed, .installedOtherVersion:
			.localized("Installed")
		case .cancelled:
			.localized("Cancelled")
		case .notInstalled, .timedOutVerifying:
			.localized("Not confirmed")
		case .timedOutWaiting:
			.localized("Not started")
		}
	}

	var cardImage: String {
		switch self {
		case .installed, .installedOtherVersion:
			"checkmark.seal.fill"
		case .cancelled:
			"xmark.circle"
		case .notInstalled, .timedOutVerifying, .timedOutWaiting:
			"questionmark.circle"
		}
	}
}
