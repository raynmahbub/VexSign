//
//  InstallCardView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import NimbleExtensions

// MARK: - View: Card
struct InstallCardView: View {
	@ObservedObject var installer: AppInstaller
	var upcoming: [AnyApp] = []
	var onCancel: () -> Void
	var onPause: (() -> Void)?
	var isPaused: Bool = false

	var body: some View {
		ZStack {
			InstallProgressView(app: installer.app, viewModel: installer.viewModel)
			InstallStatusView(
				app: installer.app,
				viewModel: installer.viewModel,
                installationPhase: installer.installationPhase,
                verificationAttempt: installer.verificationAttempt,
				upcoming: upcoming,
				onCancel: onCancel,
				onPause: onPause,
				isPaused: isPaused
			)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(NBRadius.large)
		.padding([.top, .horizontal])
		.padding(.bottom, 36)
		.ignoresSafeArea(.container, edges: .bottom)
	}
}

// MARK: - View: Status
/// Observes the status model directly
private struct InstallStatusView: View {
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
    var installationPhase: InstallConfirmation.Phase
    /// The number of the device check in flight, zero before verification starts.
    var verificationAttempt: Int
	var upcoming: [AnyApp]
	var onCancel: () -> Void
	var onPause: (() -> Void)?
	var isPaused: Bool

	var body: some View {
		ZStack {
			_status()
			_button()
			_controls()

			if !upcoming.isEmpty {
				_upNext()
			}
		}
	}

	@ViewBuilder
	private func _controls() -> some View {
		// Labeled capsule buttons instead of bare play/pause-style glyphs — the old
		// stacked round icons read as a media player's transport controls. The
		// queue pause only exists when more apps are actually waiting (otherwise
		// it would be a no-op during the current install), and every control says
		// what it does.
		HStack(spacing: 8) {
			if !viewModel.isCompleted {
				if !upcoming.isEmpty, let onPause {
					Button {
						onPause()
					} label: {
						Label(
							isPaused ? String.localized("Resume Queue") : String.localized("Pause Queue"),
							systemImage: isPaused ? "play.fill" : "pause.fill"
						)
						.font(.footnote.weight(.semibold))
						.labelStyle(.titleAndIcon)
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
					.accessibilityHint(Text(verbatim: String.localized("Holds the remaining apps; the current install finishes.")))
					.compatTransition()
				}

				Button(action: onCancel) {
					Label(String.localized("Stop Monitoring"), systemImage: "xmark")
						.font(.footnote.weight(.semibold))
						.labelStyle(.titleAndIcon)
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.accessibilityHint(Text(verbatim: String.localized("Stops VexSign monitoring and moves to the next app. An installation already accepted by iOS may continue.")))
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
		.padding(12)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
		.animation(.easeInOut(duration: 0.25), value: isPaused)
	}

    private var _statusLabel: String {
        guard case .installing = viewModel.status else { return viewModel.statusLabel }
        switch installationPhase {
        case .waitingForStart: return .localized("Waiting for iOS installation")
        // Counted from the second check, so a verification that is still waiting visibly moves.
        case .verifying: return InstallVerificationPolicy.statusLabel(attempt: verificationAttempt)
        default: return viewModel.statusLabel
        }
    }

	/// A number only when it comes from a real counter — never a manufactured percentage.
	private var _percentage: Int? {
		InstallerStatusViewModel.displayedPercentage(
			phase: installationPhase,
			overall: viewModel.overallProgress,
			isCompleted: viewModel.isCompleted
		)
	}

	@ViewBuilder
	private func _status() -> some View {
		VStack(alignment: .leading, spacing: 2) {
			// Which app this sheet is installing. The card showed an icon and a status but never
			// a name, so a queued batch gave the user no way to tell whose turn it was — or to
			// notice that a stale completion had left the previous app on screen.
			Text(app.name ?? .localized("Application"))
				.font(.subheadline.weight(.semibold))
				.lineLimit(1)
				.accessibilityIdentifier(A11y.Install.appName)
			HStack(spacing: 6) {
				Label(_statusLabel, systemImage: viewModel.statusImage)
					.labelStyle(.titleAndIcon)
				if let percentage = _percentage {
					Text(verbatim: "\(percentage)%")
						.font(.footnote.monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			.font(.footnote)
		}
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
		.animation(.smooth, value: viewModel.statusImage)
	}

	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if case .completed(.success) = viewModel.status,
			   let identifier = app.identifier, !identifier.isEmpty {
				Button {
					AppLauncher.open(identifier)
				} label: {
					NBButton(.localized("Open"), systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}

	@ViewBuilder
	private func _upNext() -> some View {
		HStack(spacing: 8) {
			HStack(spacing: -8) {
				ForEach(upcoming.prefix(4)) { entry in
					FRAppIconView(app: entry.base, size: 22)
						.overlay {
							RoundedRectangle(cornerRadius: 6, style: .continuous)
								.strokeBorder(Color(uiColor: .secondarySystemBackground), lineWidth: 2)
						}
				}
			}

			Text(String.localized("%lld queued", arguments: upcoming.count))
				.font(.caption.weight(.medium))
				.foregroundStyle(.secondary)
		}
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}
}
