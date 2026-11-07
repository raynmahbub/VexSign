//
//  InstallQueueWindow.swift
//  VexSign
//
//  Created by VexSign Team on 24.08.2026.
//

import SwiftUI
import UIKit
import NimbleExtensions

/// Its own window because the download overlay or signing cover is often already presenting, and a
/// sheet on the root hierarchy would be silently dropped.
final class InstallQueueWindow {
	static let shared = InstallQueueWindow()

	private var _window: UIWindow?
	private var _retries = 0

	private init() {}

	func ensure() {
		guard _window == nil else { return }

		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
			?? scenes.first(where: { $0.activationState == .foregroundInactive })
			?? scenes.first
		else {
			guard _retries < 20 else { return }
			_retries += 1
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.ensure() }
			return
		}

		_retries = 0

		let host = UIHostingController(rootView: InstallQueueHostView())
		host.view.backgroundColor = .clear
		host.view.isOpaque = false

		let window = InstallPassthroughWindow(windowScene: scene)
		window.windowLevel = .alert
		window.backgroundColor = .clear
		window.isOpaque = false
		window.rootViewController = host
		window.isHidden = false

		_window = window
	}

	func teardown() {
		DispatchQueue.main.async {
			guard InstallQueue.shared.current == nil else { return }
			self._window?.isHidden = true
			self._window = nil
		}
	}
}

/// Nothing but the sheet lives here, so other touches belong to the app.
private final class InstallPassthroughWindow: UIWindow {
	override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
		guard rootViewController?.presentedViewController != nil else { return nil }
		return super.hitTest(point, with: event)
	}
}

// MARK: - View: Host
private struct InstallQueueHostView: View {
	@ObservedObject private var queue = InstallQueue.shared

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
	@ObservedObject var queue: InstallQueue

	var body: some View {
		Group {
			if queue.isFinished {
				VStack(spacing: 12) {
					Text(.localized("Queue Finished"))
						.font(.headline)
					Text(verbatim: .localized("%lld succeeded · %lld failed", arguments: queue.succeededCount, queue.failedCount))
						.font(.subheadline)
						.foregroundStyle(.secondary)
					HStack(spacing: 12) {
						Button(.localized("Done")) { queue.clear() }
							.buttonStyle(.bordered)
						if queue.installedApps.count == 1, let installed = queue.installedApps.first {
							Button(.localized("Open")) {
								UIApplication.openApp(with: installed.base.identifier ?? "")
							}
							.buttonStyle(.borderedProminent)
						} else if !queue.installedApps.isEmpty {
							Menu(.localized("Open")) {
								ForEach(queue.installedApps) { installed in
									Button(installed.base.name ?? installed.base.identifier ?? .localized("App")) {
										UIApplication.openApp(with: installed.base.identifier ?? "")
									}
								}
							}
							.buttonStyle(.borderedProminent)
						}
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Color(UIColor.secondarySystemBackground))
            } else if let failure = queue.failurePresentation {
                InstallQueueFailureView(queue: queue, failure: failure)
            } else if let installer = queue.installer, let current = queue.current {
				InstallCardView(
					installer: installer,
					upcoming: queue.upcoming,
					onCancel: queue.skip,
					onPause: {
						if queue.isPaused { queue.resume() } else { queue.pause() }
					},
					isPaused: queue.isPaused
				)
				.id(current.id)
				.transition(.opacity)
			} else {
				Color(UIColor.secondarySystemBackground)
			}
		}
		.animation(.easeInOut(duration: 0.22), value: queue.index)
        .presentationDetents(queue.hasFailure ? [.medium, .large] : [.height(200)])
		.presentationDragIndicator(.visible)
		.onAppear { queue.activate() }
		.onDisappear { queue.isSheetPresented = false }
	}
}

// MARK: - View: Failure
/// Installation errors stay in the queue sheet instead of presenting a UIKit alert from another
/// window. This keeps the failure actions above the install card and avoids dismissal races.
private struct InstallQueueFailureView: View {
    @ObservedObject var queue: InstallQueue
    let failure: InstallQueue.FailurePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: failure.needsTrust ? "lock.shield" : "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(failure.needsTrust ? Color.orange : Color.red)
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
                    if failure.waitingCount > 0 {
                        Text(String.localized("%lld more apps are waiting.", arguments: failure.waitingCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button(.localized("Retry")) {
                    HeartbeatManager.shared.start(true)
                    queue.retryCurrent()
                }
                .buttonStyle(.borderedProminent)
                if failure.canRetryLocally {
                    Button(.localized("Retry with Semi Local (localhost)")) {
                        HeartbeatManager.shared.start(true)
                        queue.retryCurrent(useLocalhost: true)
                    }
                    .buttonStyle(.bordered)
                    .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button(failure.waitingCount == 0 ? String.localized("Close") : String.localized("Skip")) {
                    HeartbeatManager.shared.start(true)
                    queue.skip()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(.localized("Stop"), role: .destructive) {
                    HeartbeatManager.shared.start(true)
                    queue.stopAfterFailure()
                }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(UIColor.secondarySystemBackground))
    }
}

// MARK: - View: Pill
/// Sits in the app's own hierarchy so a dismissed install stays reachable.
struct InstallQueuePill: View {
	@ObservedObject private var queue = InstallQueue.shared
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
	private func _pill(for current: AnyApp) -> some View {
		Button {
			InstallQueueWindow.shared.ensure()
			queue.isSheetPresented = true
		} label: {
			HStack(spacing: 10) {
				FRAppIconView(app: current.base, size: 26)

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

	private func _subtitle(for current: AnyApp) -> String {
		if !queue.upcoming.isEmpty {
			return .localized("%lld queued", arguments: queue.upcoming.count)
		}

		return current.archive ? .localized("Exporting") : .localized("Installing")
	}
}
