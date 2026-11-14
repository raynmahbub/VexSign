//
//  InstallCardView.swift
//  VexSign
//
//  Created by VexSign Contributors on 22.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View: Card
struct InstallCardView: View {
	let installer: InstallationSessionState
	var upcoming: [InstallationQueueEntry] = []
	var onCancel: () -> Void
	var onPause: (() -> Void)?
	var isPaused: Bool = false

	var body: some View {
		ZStack {
            InstallProgressView(installation: installer)
			InstallStatusView(
				app: installer.app,
				installation: installer,
                hasHandedOff: installer.hasHandedOffInstall,
                isExport: installer.isExport,
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
	let installation: InstallationSessionState
    var hasHandedOff: Bool
    var isExport: Bool
    /// The number of the device check in flight, zero before verification starts.
    var verificationAttempt: Int
	var upcoming: [InstallationQueueEntry]
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
			if !_presentation.isTerminal {
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
					Label(hasHandedOff ? String.localized("Stop Monitoring") : String.localized("Cancel preparation"), systemImage: "xmark")
						.font(.footnote.weight(.semibold))
						.labelStyle(.titleAndIcon)
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.accessibilityHint(Text(verbatim: hasHandedOff
                    ? String.localized("Stops VexSign monitoring and moves to the next app. An installation already accepted by iOS may continue.")
                    : String.localized("Stops preparation before the installation request is handed off.")))
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
		.padding(12)
		.animation(.easeInOut(duration: 0.3), value: installation.isCompleted)
		.animation(.easeInOut(duration: 0.25), value: isPaused)
	}

    private var _presentation: InstallPresentation {
        installation.presentation
    }

    private var _statusLabel: String {
        _presentation.label(verificationAttempt: verificationAttempt)
    }

	/// A number only when it comes from a real counter — never a manufactured percentage.
	private var _percentage: Int? {
        installation.displayedPercentage
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
				Label(_statusLabel, systemImage: _presentation.symbol)
					.labelStyle(.titleAndIcon)
				if let percentage = _percentage {
					Text(verbatim: "\(percentage)%")
						.font(.footnote.monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			.font(.footnote)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(A11y.Install.status)
            if _presentation == .awaitingConfirmation {
                Text(verbatim: String.localized("Please confirm the installation request displayed by iOS."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
		}
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
		.animation(.smooth, value: _presentation.symbol)
	}

	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if _presentation == .installed, !isExport,
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
		.animation(.easeInOut(duration: 0.3), value: installation.isCompleted)
	}

	@ViewBuilder
	private func _upNext() -> some View {
		HStack(spacing: 8) {
			HStack(spacing: -8) {
				ForEach(upcoming.prefix(4)) { entry in
					VexAppIconView(app: entry.base, size: 22)
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
