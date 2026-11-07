//
//  SelfUpdateSheet.swift
//  VexSign
//
//  Created by VexSign Team on 05.07.2026.
//

import SwiftUI
import NimbleViews
import UIKit
import NimbleExtensions

struct SelfUpdateSheet: View {
	let release: SelfUpdateRelease
	var offersReminders: Bool = true

	@ObservedObject private var _manager = SelfUpdateManager.shared
	@Environment(\.dismiss) private var dismiss

	private var _isWorking: Bool {
		switch _manager.phase {
		case .downloading, .importing, .signing, .installing, .done: return true
		default: return false
		}
	}

	private var _locksDismiss: Bool {
		switch _manager.phase {
		case .downloading, .importing, .signing: return true
		default: return false
		}
	}

	var body: some View {
		NBNavigationView(release.isInstalled ? .localized("Reinstall") : .localized("Update Available")) {
			ZStack {
				if _isWorking {
					_busy
						.transition(.scale(scale: 0.92).combined(with: .opacity))
				} else {
					ScrollView {
						VStack(alignment: .leading, spacing: 20) {
							_header
							if !release.notes.isEmpty {
								_notes
							}
						}
						.padding()
					}
					.safeAreaInset(edge: .bottom) { _footer }
					.transition(.opacity)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.animation(.spring(response: 0.42, dampingFraction: 0.82), value: _isWorking)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(.localized("Close")) { dismiss() }
						.disabled(_locksDismiss)
				}
			}
			.interactiveDismissDisabled(_locksDismiss)
			.onDisappear { _manager.endFlow() }
		}
	}

	// MARK: Header

	private var _header: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 14) {
				Image(uiImage: UIImage(named: Bundle.main.iconFileName ?? "") ?? UIImage())
					.resizable()
					.frame(width: 60, height: 60)
					.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
				VStack(alignment: .leading, spacing: 3) {
					Text(release.title)
						.font(.title3.bold())
					HStack(spacing: 6) {
						Text(Bundle.main.version)
						Image(systemName: "arrow.right")
							.font(.caption2)
						Text(release.version)
							.foregroundStyle(Color.accentColor)
					}
					.font(.subheadline)
					.foregroundStyle(.secondary)
				}
				Spacer(minLength: 0)
			}
			if let date = release.publishedAt {
				Text(date.formatted(date: .abbreviated, time: .omitted))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	private var _notes: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(.localized("What's New"))
				.font(.headline)
			MarkdownView(text: release.notes)
				.foregroundStyle(.secondary)
				.textSelection(.enabled)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	// MARK: Working state

	private var _busy: some View {
		VStack(spacing: 22) {
			Spacer()
			Image(uiImage: UIImage(named: Bundle.main.iconFileName ?? "") ?? UIImage())
				.resizable()
				.frame(width: 72, height: 72)
				.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

			ZStack {
				if let value = _determinateValue {
					Circle()
						.stroke(Color.secondary.opacity(0.2), lineWidth: 6)
					Circle()
						.trim(from: 0, to: value)
						.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
						.rotationEffect(.degrees(-90))
						.animation(.easeInOut(duration: 0.25), value: value)
					Text("\(Int(value * 100))%")
						.font(.callout.bold().monospacedDigit())
						.contentTransition(.numericText())
				} else {
					ProgressView()
						.controlSize(.large)
						.scaleEffect(1.3)
				}
			}
			.frame(width: 92, height: 92)
			.transition(.opacity)
			.animation(.smooth(duration: 0.3), value: _determinateValue == nil)

			VStack(spacing: 4) {
				Text(_statusText)
					.font(.headline)
					.contentTransition(.opacity)
				if case .installing = _manager.phase {
					Text(.localized("Installing on the Home Screen. You can close this."))
						.font(.caption)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
			}
			.animation(.smooth(duration: 0.25), value: _statusText)

			Spacer()

			if !_locksDismiss {
				Button(.localized("Close")) {
					_manager.phase = .idle
					dismiss()
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding()
	}

	// MARK: Footer

	@ViewBuilder
	private var _footer: some View {
		VStack(spacing: 10) {
			if case .failed(let message) = _manager.phase {
				_failure(message)
			} else if let blocker = _plan.blocker {
				_blocked(blocker)
			} else {
				_actions
			}
		}
		.padding()
		.background(.bar)
	}

	// MARK: Readiness

	private var _plan: SelfUpdatePlan { _manager.plan(for: release) }

	private var _methodBinding: Binding<SelfUpdateMethod> {
		Binding(get: { _manager.method }, set: { _manager.adopt($0) })
	}

	/// Fixing the method belongs in the sheet: sending someone to Settings to change a picker and
	/// come back is how the Install button ended up doing nothing but printing an error.
	private var _methodPicker: some View {
		Picker(.localized("Install Method"), selection: _methodBinding) {
			Text(SelfUpdateMethod.server.title).tag(SelfUpdateMethod.server)
			Text(SelfUpdateMethod.idevice.title).tag(SelfUpdateMethod.idevice)
		}
		.pickerStyle(.segmented)
	}

	private func _installButton(_ title: String) -> some View {
		Button {
			_manager.beginUpdate(to: release)
		} label: {
			Text(verbatim: title).frame(maxWidth: .infinity)
		}
		.buttonStyle(.borderedProminent)
		.controlSize(.large)
	}

	/// Shown instead of the Install button when the selected method cannot work, so the reason and
	/// the way out appear before anything is attempted.
	private func _blocked(_ blocker: SelfUpdateBlocker) -> some View {
		VStack(spacing: 10) {
			Label(blocker.message, systemImage: "exclamationmark.triangle.fill")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)

			if let alternative = _plan.alternative {
				_installButton(String.localized("Install with %@", arguments: alternative.title))
			}

			if !blocker.isFinal {
				_methodPicker
			}

			if _manager.method == .idevice && !_manager.hasPairing {
				Button {
					UIApplication.open("localdevvpn://enable?scheme=vexsign")
				} label: {
					Label(.localized("Connect to LocalDevVPN"), systemImage: "link")
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			}

			Button {
				_manager.phase = .idle
				dismiss()
			} label: {
				Text(.localized("Close")).frame(maxWidth: .infinity)
			}
			.buttonStyle(.bordered)
			.controlSize(.large)
		}
	}

	private var _actions: some View {
		VStack(spacing: 10) {
			Label(.localized("Sign with the certificate you first installed VexSign with, or iOS won't update it in place."), systemImage: "info.circle")
				.font(.caption)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)

			Button {
				_manager.beginUpdate(to: release)
			} label: {
				Text(verbatim: release.isInstalled ? .localized("Reinstall %@", arguments: release.version) : .localized("Update Now"))
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.large)

			if offersReminders {
				HStack(spacing: 10) {
					Button { dismiss() } label: {
						Text(.localized("Remind Me Later")).frame(maxWidth: .infinity)
					}
					Button(role: .destructive) {
						_manager.ignore(release.version)
						dismiss()
					} label: {
						Text(.localized("Ignore This Version")).frame(maxWidth: .infinity)
					}
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			}
		}
	}

	private var _determinateValue: Double? {
		switch _manager.phase {
		case .downloading(let value): return value
		case .installing where _manager.installProgress > 0: return _manager.installProgress
		default: return nil
		}
	}

	private func _failure(_ message: String) -> some View {
		VStack(spacing: 10) {
			Label(message, systemImage: "exclamationmark.triangle.fill")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)

			if let blocker = _plan.blocker {
				// Nothing about this build or its settings changed, so "Try Again" would repeat the
				// same sentence. Offer what can actually proceed instead.
				if let alternative = _plan.alternative {
					_installButton(String.localized("Install with %@", arguments: alternative.title))
				}
				if !blocker.isFinal {
					_methodPicker
				}
			} else {
				if _manager.method == .idevice {
					Button {
						UIApplication.open("localdevvpn://enable?scheme=vexsign")
					} label: {
						Label(.localized("Connect to LocalDevVPN"), systemImage: "link")
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
				}
				HStack(spacing: 10) {
					Button {
						_manager.phase = .idle
						dismiss()
					} label: {
						Text(.localized("Close")).frame(maxWidth: .infinity)
					}
					Button {
						_manager.beginUpdate(to: release)
					} label: {
						Text(.localized("Try Again")).frame(maxWidth: .infinity)
					}
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			}

			if _plan.blocker != nil {
				Button {
					_manager.phase = .idle
					dismiss()
				} label: {
					Text(.localized("Close")).frame(maxWidth: .infinity)
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			}
		}
	}

	private var _statusText: String {
		switch _manager.phase {
		case .downloading: return .localized("Downloading")
		case .importing: return .localized("Preparing")
		case .signing: return .localized("Signing")
		case .installing: return .localized("Installing")
		case .done: return .localized("Finishing")
		default: return ""
		}
	}
}
