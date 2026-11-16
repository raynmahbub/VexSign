import SwiftUI
import UIKit
import NimbleExtensions
import NimbleViews

// MARK: - View: Host
struct InstallQueueHostView: View {
	@ObservedObject var queue: InstallationQueueModel

	var body: some View {
		Color.clear
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.sheet(isPresented: $queue.isSheetPresented, onDismiss: queue.sheetDismissed) {
				InstallQueueSheet(queue: queue)
			}
	}
}

// MARK: - View: Sheet
private struct InstallQueueSheet: View {
	@ObservedObject var queue: InstallationQueueModel

	/// The same state the pill and the library badge read, resolved once so the sheet cannot
	/// disagree with the queue about whether an installation is still in flight.
	private var surface: InstallQueueSurface {
		InstallQueueSurface.resolve(
			isPresented: true,
			isFinished: queue.isFinished,
			failureTitle: queue.failurePresentation?.title,
			hasInstaller: queue.installer != nil,
			isPaused: queue.isPaused,
			currentEntryID: queue.current?.id,
			succeeded: queue.succeededCount,
			failed: queue.failedCount
		)
	}

	var body: some View {
		_surfaceView(surface)
			.animation(.easeInOut(duration: 0.22), value: queue.index)
			.presentationDetents(queue.hasFailure ? [.medium, .large] : [.height(250), .medium])
			.presentationDragIndicator(.visible)
			.onAppear { queue.activate() }
	}

	@ViewBuilder
	private func _surfaceView(_ surface: InstallQueueSurface) -> some View {
		switch surface {
		case .hidden, .preparing:
			Color(UIColor.secondarySystemBackground)
		case .finished(let succeeded, let failed):
			_summary(succeeded: succeeded, failed: failed)
		case .report:
			if let failure = queue.failurePresentation {
				InstallQueueFailureView(queue: queue, failure: failure, entryID: queue.current?.id)
			} else {
				Color(UIColor.secondarySystemBackground)
			}
		case .installing(let entryID):
			// The entry the queue says is current is the entry drawn: a completion from an
			// abandoned run cannot put a stale card back on screen.
			if let installer = queue.installer, let current = queue.current, current.id == entryID {
				InstallCardView(
					installer: installer,
					upcoming: queue.upcoming,
					onCancel: { queue.skip(forEntryID: current.id) },
					onPause: {
						if queue.isPaused { queue.resume() } else { queue.pause() }
					},
					isPaused: queue.isPaused
				)
                .sheet(isPresented: Binding(get: { installer.isPresentingFallbackPage }, set: { queue.setFallbackPresented($0) })) {
                    if let url = installer.fallbackPageURL { SafariRepresentableView(url: url).ignoresSafeArea() }
                }
				.id(current.id)
				.transition(.opacity)
			} else {
				Color(UIColor.secondarySystemBackground)
			}
		case .paused(let entryID):
			if let current = queue.current, current.id == entryID {
				InstallQueuePausedView(
					app: current,
					onResume: queue.resume,
					onSkip: { queue.skip(forEntryID: current.id) }
				)
					.id(current.id)
					.transition(.opacity)
			} else {
				Color(UIColor.secondarySystemBackground)
			}
		}
	}

	/// The terminal summary. Reached only once the queue really finished, so it is what proves
	/// the sheet left a completed run rather than an abandoned one.
	@ViewBuilder
	private func _summary(succeeded: Int, failed: Int) -> some View {
		VStack(spacing: 12) {
			Text(.localized("Queue Finished"))
				.font(.headline)
			Text(verbatim: .localized("%lld succeeded · %lld failed", arguments: succeeded, failed))
				.font(.subheadline)
				.foregroundStyle(.secondary)
			HStack(spacing: 12) {
				Button(.localized("Done")) { queue.clear() }
					.buttonStyle(.bordered)
				if queue.installedApps.count == 1, let installed = queue.installedApps.first {
					Button(.localized("Open")) {
						AppLauncher.open(installed.base.identifier ?? "")
					}
					.buttonStyle(.borderedProminent)
				} else if !queue.installedApps.isEmpty {
					Menu(.localized("Open")) {
						ForEach(queue.installedApps) { installed in
							Button(installed.base.name ?? installed.base.identifier ?? .localized("App")) {
								AppLauncher.open(installed.base.identifier ?? "")
							}
						}
					}
					.buttonStyle(.borderedProminent)
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(UIColor.secondarySystemBackground))
	}
}

// MARK: - View: Failure
/// Installation errors stay in the queue sheet instead of presenting a UIKit alert from another
/// window. This keeps the failure actions above the install card and avoids dismissal races.
private struct InstallQueueFailureView: View {
    @ObservedObject var queue: InstallationQueueModel
    let failure: InstallationFailure
    let entryID: String?
    @State private var confirmRetryAfterDeviceCheck = false
    @State private var retryUsingLocalhost = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: failure.needsTrust ? "lock.shield" :
                    (failure.requiresDeviceCheckBeforeRetry ? "questionmark.circle.fill" : "exclamationmark.triangle.fill"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(failure.needsTrust || failure.requiresDeviceCheckBeforeRetry ? Color.orange : Color.red)
                Text(failure.title)
                    .font(.headline)
                    .lineLimit(2)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(failure.message)
                        .font(.subheadline)
                    Text(failure.details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let report = queue.latestReport {
                        DisclosureGroup(.localized("View Report")) {
                            Text(report)
                                .font(.caption.monospaced()).textSelection(.enabled)
                            Button(.localized("Copy Redacted Report")) {
                                UIPasteboard.general.string = report
                            }
                        }
                    }
                    if failure.waitingCount > 0 {
                        Text(String.localized("%lld more apps are waiting.", arguments: failure.waitingCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button(.localized("Retry Install")) {
                    _requestRetry(useLocalhost: false)
                }
                .buttonStyle(.borderedProminent)
                if failure.canRetryLocally {
                    Button(.localized("Retry with Semi Local (localhost)")) {
                        _requestRetry(useLocalhost: true)
                    }
                    .buttonStyle(.bordered)
                    .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button(failure.waitingCount == 0 ? String.localized("Close") : String.localized("Skip")) {
                    queue.skip(forEntryID: entryID)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(.localized("Stop"), role: .destructive) {
                    queue.stopAfterFailure()
                }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(UIColor.secondarySystemBackground))
        .confirmationDialog(.localized("Install again?"), isPresented: $confirmRetryAfterDeviceCheck, titleVisibility: .visible) {
            Button(.localized("I Checked — Install Again")) {
                queue.retryCurrent(entryID: entryID, useLocalhost: retryUsingLocalhost,
                    afterManualDeviceCheck: true)
            }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("If the requested version is already on the Home Screen, open it instead. Only choose Install Again after checking the app version and confirming the requested version is not installed; VexSign cannot verify that manual check."))
        }
    }

    private func _requestRetry(useLocalhost: Bool) {
        guard failure.requiresDeviceCheckBeforeRetry else {
            queue.retryCurrent(entryID: entryID, useLocalhost: useLocalhost)
            return
        }
        retryUsingLocalhost = useLocalhost
        confirmRetryAfterDeviceCheck = true
    }
}

// MARK: - View: Paused queue
/// A completed item can advance into a held next item without creating an installer. Keep
/// the sheet actionable instead of leaving a blank surface with no way to resume the queue.
private struct InstallQueuePausedView: View {
    let app: InstallationQueueEntry
    let onResume: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VexAppIconView(app: app.base, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(.localized("Queue paused"))
                        .font(.headline)
                    Text(verbatim: app.base.name ?? String.localized("App"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: onResume) {
                    Label(String.localized("Resume Queue"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button(action: onSkip) {
                    Label(String.localized("Skip"), systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
    }
}

// MARK: - View: Pill
/// Sits in the app's own hierarchy so a dismissed install stays reachable.
struct InstallQueuePill: View {
	@EnvironmentObject private var queue: InstallationQueueModel
	@ObservedObject private var bottomBar = BottomBarMetrics.shared

	var body: some View {
		ZStack {
			if queue.showsPill, let current = queue.current {
				_pill(for: current)
					.transition(.move(edge: .bottom).combined(with: .opacity))
			}
		}
		.animation(.spring(response: 0.4, dampingFraction: 0.85), value: queue.showsPill)
		.animation(.spring(response: 0.35, dampingFraction: 0.9), value: bottomBar.height)
	}

	@ViewBuilder
	private func _pill(for current: InstallationQueueEntry) -> some View {
		Button {
			queue.isSheetPresented = true
		} label: {
			HStack(spacing: 10) {
				VexAppIconView(app: current.base, size: 26)

				VStack(alignment: .leading, spacing: 1) {
					Text(verbatim: current.base.name ?? String.localized("App"))
						.font(.footnote.weight(.semibold))
						.foregroundStyle(.primary)
						.lineLimit(1)

					Text(_subtitle(for: current))
						.font(.caption2)
						.foregroundStyle(.secondary)
				}

				Image(systemName: "chevron.up")
					.font(.caption.weight(.bold))
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
			.background(
				Capsule(style: .continuous)
					.fill(.ultraThinMaterial)
					.overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
			)
			.shadow(color: .black.opacity(0.22), radius: 16, y: 6)
		}
		.buttonStyle(.plain)
		.padding(.bottom, 60 + bottomBar.height)
	}

	private func _subtitle(for current: InstallationQueueEntry) -> String {
        if queue.failurePresentation != nil { return .localized("Needs review — View Report") }
		if !queue.upcoming.isEmpty {
			return .localized("%lld queued", arguments: queue.upcoming.count)
		}

		return current.archive ? .localized("Exporting") : .localized("Installing")
	}
}
