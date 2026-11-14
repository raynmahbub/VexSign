//
//  WatchHomeView.swift
//  VexSignWatch
//
//  Wrist-sized summary: the certificate countdown, three counts, and the four
//  passes the phone can run for you. Everything is a mirror of iPhone state.
//

import SwiftUI

struct WatchHomeView: View {
	@EnvironmentObject private var store: WatchSessionStore

	var body: some View {
		List {
			_certificateSection
			_countsSection
			_actionsSection
			_statusSection
		}
		.navigationTitle("VexSign")
	}

	// MARK: Sections

	private var _certificateSection: some View {
		let status = store.snapshot?.status

		return Section {
			NavigationLink {
				WatchLibraryView()
			} label: {
				VStack(alignment: .leading, spacing: 2) {
					Text(status?.certLabel ?? "—")
						.font(.system(size: 40, weight: .bold, design: .rounded))
						.foregroundStyle(_certTint)
						.contentTransition(.numericText())
					Text(status?.certSummary ?? "Waiting for iPhone…")
						.font(.caption2)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}
			}
		}
	}

	private var _certTint: Color {
		guard let status = store.snapshot?.status else { return .secondary }
		if status.certRevoked { return .red }
		guard let days = status.certDaysRemaining else { return .secondary }
		if days < 7 { return .red }
		if days < 30 { return .orange }
		return .green
	}

	private var _countsSection: some View {
		let status = store.snapshot?.status

		return Section {
			_row("Apps", value: status.map { "\($0.installedApps)" } ?? "—", icon: "square.grid.2x2")
			_row("Signed", value: status.map { "\($0.signedApps)" } ?? "—", icon: "signature")
			_row("Updates", value: status.map { "\($0.pendingUpdates)" } ?? "—", icon: "arrow.up.circle")
		}
	}

	private func _row(_ title: String, value: String, icon: String) -> some View {
		HStack(spacing: 8) {
			Image(systemName: icon)
				.font(.caption)
				.foregroundStyle(.secondary)
			Text(title)
				.font(.footnote)
			Spacer()
			Text(value)
				.font(.footnote.bold())
				.contentTransition(.numericText())
		}
	}

	private var _actionsSection: some View {
		Section("Run on iPhone") {
			ForEach(CompanionCommand.allCases, id: \.rawValue) { command in
				Button {
					store.send(command)
				} label: {
					Label(command.title, systemImage: _icon(for: command))
						.font(.footnote)
				}
			}
		}
	}

	private func _icon(for command: CompanionCommand) -> String {
		switch command {
		case .refreshSources: return "arrow.clockwise"
		case .checkCertificates: return "checkmark.shield"
		case .updateAll: return "arrow.triangle.2.circlepath"
		case .cleanNow: return "sparkles"
		}
	}

	private var _statusSection: some View {
		Section {
			HStack(spacing: 6) {
				Circle()
					.fill(store.isReachable ? Color.green : Color.secondary)
					.frame(width: 7, height: 7)
				Text(store.isReachable ? "iPhone reachable" : "Waiting for iPhone")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}

			if let command = store.lastCommand {
				Text("Last: \(command)")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}

			if let generated = store.snapshot?.generatedAt {
				Text("Snapshot \(generated, style: .relative) ago")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
		}
	}
}
