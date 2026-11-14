//
//  TVHomeView.swift
//  VexSignTV
//
//  The television layout: one screen, everything the iPhone reports, big enough
//  to read from a sofa. Focus moves card → actions → lists, which is the only
//  navigation model tvOS has.
//

import SwiftUI

struct TVHomeView: View {
	@EnvironmentObject private var store: CompanionStore
	@State private var _showConnect = false

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 28) {
				_header
				if let error = store.lastError {
					Label(error, systemImage: "exclamationmark.triangle.fill")
						.font(.callout)
						.foregroundStyle(.red)
				}
				if let error = store.credentialStorageError {
					Label(error, systemImage: "key.horizontal.fill")
						.font(.callout)
						.foregroundStyle(.orange)
				}
				if let error = store.certificateTrustError {
					Label(error, systemImage: "checkmark.seal")
						.font(.callout)
						.foregroundStyle(.orange)
				}
				_certificateCard
				_countsRow
				_updatesSection
				_librarySection
			}
			.padding(48)
		}
		.sheet(isPresented: $_showConnect) {
			TVConnectView()
		}
		.overlay(alignment: .topTrailing) {
			if store.isRefreshing {
				ProgressView()
					.padding(24)
			}
		}
	}

	// MARK: Header

	private var _header: some View {
		HStack(alignment: .firstTextBaseline) {
			VStack(alignment: .leading, spacing: 2) {
				Text("VexSign")
					.font(.largeTitle.bold())
				if let updated = store.lastUpdated {
					Text("Updated \(updated, style: .relative) ago")
						.font(.callout)
						.foregroundStyle(.secondary)
				}
			}

			Spacer()

			Button {
				Task { await store.refresh() }
			} label: {
				Label("Refresh", systemImage: "arrow.clockwise")
			}

			Button {
				_showConnect = true
			} label: {
				Label("Connection", systemImage: "wifi")
			}
		}
	}

	// MARK: Certificate

	private var _certificateCard: some View {
		let status = store.snapshot?.status

		return HStack(spacing: 24) {
			Image(systemName: (status?.certRevoked ?? false) ? "xmark.seal.fill" : "checkmark.seal.fill")
				.font(.system(size: 52))
				.foregroundStyle(_certTint)

			VStack(alignment: .leading, spacing: 4) {
				Text(status?.certLabel ?? "—")
					.font(.system(size: 64, weight: .bold, design: .rounded))
					.foregroundStyle(_certTint)
					.contentTransition(.numericText())
				Text(status?.certSummary ?? "Waiting for the iPhone…")
					.font(.title3)
					.foregroundStyle(.secondary)
				if let name = status?.certName {
					Text(name)
						.font(.callout)
						.foregroundStyle(.secondary)
				}
			}

			Spacer()
		}
		.padding(28)
		.background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
	}

	private var _certTint: Color {
		guard let status = store.snapshot?.status else { return .secondary }
		if status.certRevoked { return .red }
		guard let days = status.certDaysRemaining else { return .secondary }
		if days < 7 { return .red }
		if days < 30 { return .orange }
		return .green
	}

	// MARK: Counts

	private var _countsRow: some View {
		let status = store.snapshot?.status

		return HStack(spacing: 20) {
			_countTile("Apps", value: status.map { "\($0.installedApps)" } ?? "—", icon: "square.grid.2x2")
			_countTile("Signed", value: status.map { "\($0.signedApps)" } ?? "—", icon: "signature")
			_countTile("Updates", value: status.map { "\($0.pendingUpdates)" } ?? "—", icon: "arrow.up.circle")
			_countTile(
				"Free",
				value: status?.storageFree.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—",
				icon: "internaldrive"
			)
		}
	}

	private func _countTile(_ title: String, value: String, icon: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Label(title, systemImage: icon)
				.font(.callout)
				.foregroundStyle(.secondary)
			Text(value)
				.font(.title.bold())
				.contentTransition(.numericText())
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(20)
		.background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
	}

	// MARK: Updates

	private var _updatesSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Pending updates")
				.font(.title3.bold())
			_updatesContent
		}
	}

	@ViewBuilder
	private var _updatesContent: some View {
		if let result = store.updatesResult {
			switch result {
			case .success(let updates):
				if updates.isEmpty {
					Text("Everything is up to date.")
						.font(.callout)
						.foregroundStyle(.secondary)
				} else {
					ForEach(updates.prefix(12)) { update in
						HStack {
							VStack(alignment: .leading, spacing: 2) {
								Text(update.name)
									.font(.headline)
								Text(update.bundleID)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Spacer()
							Text("\(update.installedVersion ?? "?") → \(update.availableVersion ?? "?")")
								.font(.callout.monospacedDigit())
								.foregroundStyle(.orange)
						}
						.padding(16)
						.background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
					}
				}
			case .failure(let error):
				_endpointFailure("Updates", error: error)
			}
		} else {
			Text(store.isRefreshing ? "Loading updates…" : "Updates have not been loaded yet.")
				.font(.callout)
				.foregroundStyle(.secondary)
		}
	}

	// MARK: Library

	private var _librarySection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Library")
				.font(.title3.bold())
			_libraryContent
		}
	}

	@ViewBuilder
	private var _libraryContent: some View {
		if let result = store.libraryResult {
			switch result {
			case .success(let library):
				if library.isEmpty {
					Text("Nothing in the library yet.")
						.font(.callout)
						.foregroundStyle(.secondary)
				} else {
					LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], alignment: .leading, spacing: 16) {
						ForEach(library.prefix(24)) { app in
							HStack(spacing: 12) {
								Image(systemName: app.signed ? "checkmark.seal.fill" : "app.dashed")
									.foregroundStyle(app.signed ? .green : .secondary)
								VStack(alignment: .leading, spacing: 2) {
									Text(app.name)
										.font(.headline)
										.lineLimit(1)
									Text("\(app.version) · \(app.bundleID)")
										.font(.caption)
										.foregroundStyle(.secondary)
										.lineLimit(1)
								}
								Spacer(minLength: 0)
							}
							.padding(16)
							.background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
						}
					}
				}
			case .failure(let error):
				_endpointFailure("Library", error: error)
			}
		} else {
			Text(store.isRefreshing ? "Loading library…" : "The library has not been loaded yet.")
				.font(.callout)
				.foregroundStyle(.secondary)
		}
	}

	private func _endpointFailure(_ section: String, error: CompanionClientError) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Label(
				error.isAuthenticationFailure ? "Authentication failed" : "\(section) temporarily unavailable",
				systemImage: error.isAuthenticationFailure ? "lock.fill" : "exclamationmark.triangle.fill"
			)
			Text(error.localizedDescription)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.foregroundStyle(error.isAuthenticationFailure ? Color.red : Color.orange)
	}
}
