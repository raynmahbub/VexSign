//
//  DiagnosticsCenterView.swift
//  VexSign
//
//  One place for the health of the whole app: certificates, repositories,
//  storage, device/pairing state, the unified task history and exportable
//  logs. Aggregates existing subsystems rather than duplicating them —
//  deep dives stay in their own views (Certificate Dashboard, System
//  Diagnostics, Storage).
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import CoreData

struct DiagnosticsCenterView: View {
    @ObservedObject private var migration = CredentialMigrationDiagnostics.shared
	@ObservedObject private var taskCenter = UnifiedTaskCenter.shared
	@ObservedObject private var sourcesViewModel = SourcesViewModel.shared

	@FetchRequest(entity: CertificatePair.entity(), sortDescriptors: [])
	private var certificates: FetchedResults<CertificatePair>

	@FetchRequest(entity: AltSource.entity(), sortDescriptors: [])
	private var sources: FetchedResults<AltSource>

	@State private var _isExporting = false

	var body: some View {
		NBNavigationView(.localized("Diagnostics"), displayMode: .inline) {
			List {
                if !migration.warnings.isEmpty {
                    Section {
                        ForEach(migration.warnings, id: \.self) { warning in
                            Label(warning.message, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                        }
                    }
                }

				overviewSection
				certificatesSection
				repositoriesSection
				storageSection
				deviceSection
				taskHistorySection
				exportSection
			}
			.navigationTitle(.localized("Diagnostics"))
		}
	}

	// MARK: - Overview

	private var overviewSection: some View {
		NBSection(.localized("Overview"), systemName: "cross.case.fill") {
			let failingSources = sources.filter {
				let id = $0.identifier ?? $0.sourceURL?.absoluteString ?? ""
				return SourcePreferences.lastError(for: id) != nil
			}
			let expiringCerts = certificates.filter {
				guard let expiration = $0.expiration else { return false }
				return expiration.timeIntervalSinceNow < 14 * 86_400
			}

			_row(.localized("Certificates"), value: certificates.count, icon: "checkmark.seal.fill", tint: .green)
			_row(.localized("Expiring Certificates"), value: expiringCerts.count, icon: "exclamationmark.triangle.fill", tint: expiringCerts.isEmpty ? .green : .orange)
			_row(.localized("Repositories"), value: sources.count, icon: "globe.desk.fill", tint: .blue)
			_row(.localized("Failing Repositories"), value: failingSources.count, icon: "exclamationmark.bubble.fill", tint: failingSources.isEmpty ? .green : .orange)
			_row(.localized("Showing Saved Copies"), value: sourcesViewModel.staleSourceIDs.count, icon: "clock.badge.exclamationmark", tint: sourcesViewModel.staleSourceIDs.isEmpty ? .green : .blue)
		} footer: {
			Text(.localized("A snapshot right now. Each card links to the subsystem that owns it."))
		}
	}

	private func _row(_ title: String, value: Int, icon: String, tint: Color) -> some View {
		HStack(spacing: 12) {
			Image(systemName: icon)
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(tint)
				.frame(width: 24)
			Text(title)
			Spacer()
			Text("\(value)")
				.font(.subheadline.bold().monospacedDigit())
				.foregroundStyle(.secondary)
		}
		.accessibilityElement(children: .combine)
		.accessibilityLabel(Text(verbatim: "\(title): \(value)"))
	}

	// MARK: - Certificates

	private var certificatesSection: some View {
		NBSection(.localized("Certificate Health"), systemName: "checkmark.seal.fill") {
			if certificates.isEmpty {
				Text(.localized("No certificates imported."))
					.font(.caption)
					.foregroundStyle(.secondary)
			} else {
				ForEach(Array(certificates), id: \.objectID) { cert in
					let days = cert.expiration.map { Int($0.timeIntervalSinceNow / 86_400) }
					HStack(spacing: 12) {
						Image(systemName: "checkmark.seal")
							.foregroundStyle((days ?? 999) < 14 ? .orange : .green)
						VStack(alignment: .leading, spacing: 2) {
							Text(cert.nickname ?? cert.uuid ?? .localized("Certificate"))
								.font(.subheadline)
							if let days {
								Text(verbatim: days > 0
									? String.localized("%lld days remaining", arguments: days)
									: .localized("Expired"))
									.font(.caption2)
									.foregroundStyle(days < 14 ? .orange : .secondary)
							}
						}
					}
				}
				NavigationLink(destination: CertificateDashboardView()) {
					Label(.localized("Certificate Dashboard"), systemImage: "chart.line.uptrend.xyaxis")
				}
			}
		}
	}

	// MARK: - Repositories

	private var repositoriesSection: some View {
		NBSection(.localized("Repositories"), systemName: "globe.desk.fill") {
			NavigationLink(destination: SourceHealthDashboardView()) {
				Label(.localized("Source Health"), systemImage: "heart.text.clipboard")
			}
			if let failing = _failingSourceNames(), !failing.isEmpty {
				ForEach(failing.prefix(3), id: \.self) { name in
					Label(name, systemImage: "exclamationmark.triangle.fill")
						.font(.caption)
						.foregroundStyle(.orange)
				}
			}
		} footer: {
			Text(.localized("Last successful refresh, failure reasons, retry counts and rate-limit status per repository."))
		}
	}

	private func _failingSourceNames() -> [String]? {
		sources.compactMap { source in
			let id = source.identifier ?? source.sourceURL?.absoluteString ?? ""
			guard SourcePreferences.lastError(for: id) != nil else { return nil }
			return source.name ?? id
		}
	}

	// MARK: - Storage

	private var storageSection: some View {
		NBSection(.localized("Storage"), systemName: "internaldrive.fill") {
			NavigationLink(destination: StorageView()) {
				Label(.localized("Storage Overview"), systemImage: "chart.pie.fill")
			}
			NavigationLink(destination: CleanupView()) {
				Label(.localized("Auto Cleanup"), systemImage: "trash.slash.fill")
			}
		} footer: {
			Text(.localized("Signed apps, imported archives, temporary files and the offline source snapshot cache."))
		}
	}

	// MARK: - Device

	private var deviceSection: some View {
		NBSection(.localized("Device & Installation"), systemName: "iphone.gen3") {
			NavigationLink(destination: DeviceDiagnosticsView()) {
				Label(.localized("System Diagnostics"), systemImage: "info.circle.fill")
			}
			NavigationLink(destination: TunnelView()) {
				Label(.localized("Pairing & Tunnel"), systemImage: "cable.connector")
			}
			NavigationLink(destination: JITSettingsView()) {
				Label(.localized("JIT & Entitlements"), systemImage: "bolt.badge.automatic.fill")
			}
		} footer: {
			Text(.localized("Pairing file state, tunnel connectivity and JIT availability for the current signing setup."))
		}
	}

	// MARK: - Task history

	private var taskHistorySection: some View {
		NBSection(.localized("Download & Signing History"), systemName: "clock.arrow.circlepath") {
			NavigationLink(destination: TaskCenterView()) {
				Label(.localized("Task Center"), systemImage: "list.bullet.rectangle")
			}
			NavigationLink(destination: LogsHistoryView()) {
				Label(.localized("Activity Logs"), systemImage: "doc.text.magnifyingglass")
			}
			if !taskCenter.history.isEmpty {
				ForEach(taskCenter.history.prefix(5), id: \.id) { task in
					HStack(spacing: 10) {
						Image(systemName: task.kind.icon)
							.font(.system(size: 13, weight: .semibold))
							.foregroundStyle(task.phase == .failed ? .orange : .secondary)
						Text(task.title)
							.font(.caption)
							.lineLimit(1)
						Spacer()
						Text(task.phase.title)
							.font(.caption2)
							.foregroundStyle(task.phase == .failed ? .orange : .secondary)
					}
				}
			}
		} footer: {
			Text(.localized("Unified download/import/signing/install history with the exact failure stage."))
		}
	}

	// MARK: - Export

	private var exportSection: some View {
		NBSection(.localized("Export"), systemName: "square.and.arrow.up.fill") {
			Button {
				_exportDiagnostics()
			} label: {
				if _isExporting {
					HStack {
						Text(.localized("Preparing…"))
						Spacer()
						ProgressView().controlSize(.small)
					}
				} else {
					Label(.localized("Export Diagnostics Bundle"), systemImage: "doc.zipper")
				}
			}
			.disabled(_isExporting)
		} footer: {
			Text(.localized("A sanitized zip with activity logs, environment info, certificate metadata (no private keys, no passwords) and signing configuration — ready to attach to a bug report."))
		}
	}

	private func _exportDiagnostics() {
		_isExporting = true
		// The exporter is main-actor isolated; run it in an inheriting task so
		// the state updates land back on main automatically.
		Task { @MainActor in
			let url = DiagnosticBundleExporter.createDiagnosticBundle()
			_isExporting = false
			if let url {
				// Same direct-share pattern the other log/diagnostic views use.
				UIActivityViewController.show(activityItems: [url])
			} else {
				Toast.error(.localized("Could not create the diagnostics bundle."))
			}
		}
	}
}
