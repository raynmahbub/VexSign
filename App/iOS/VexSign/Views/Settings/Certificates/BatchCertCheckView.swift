//
//  BatchCertCheckView.swift
//  VexSign
//
//  Result table for `BatchCertChecker`: one colour-coded row per certificate with
//  expiry, revocation, PPQ/PPQLess and JIT support. Presented from the
//  Certificates toolbar ("Check All").
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct BatchCertCheckView: View {
	@ObservedObject private var _checker = BatchCertChecker.shared

	@State private var _checkOnline = false

	var body: some View {
		NBNavigationView(.localized("Check All Certificates"), displayMode: .inline) {
			List {
				_summarySection

				if _checker.isRunning {
					_progressSection
				}

				_resultsSection
			}
			.toolbar {
				NBToolbarButton(role: .close)
			}
		}
		.task {
			// The button in CertificatesView kicks the check off before presenting;
			// this only covers presenting the view directly (and re-runs are no-ops
			// while one is already in flight).
			if _checker.results.isEmpty, !_checker.isRunning {
				await _checker.checkAll(online: _checkOnline)
			}
		}
	}

	// MARK: Sections

	@ViewBuilder
	private var _summarySection: some View {
		NBSection(.localized("Summary")) {
			let summary = _checker.summary

			HStack(spacing: 10) {
				_stat(String.localized("%lld valid", arguments: summary.valid), color: .green)
				if summary.expiring > 0 {
					_stat(String.localized("%lld expiring", arguments: summary.expiring), color: .orange)
				}
				if summary.expired > 0 {
					_stat(String.localized("%lld expired", arguments: summary.expired), color: .red)
				}
				if summary.revoked > 0 {
					_stat(String.localized("%lld revoked", arguments: summary.revoked), color: .red)
				}
				if _checker.notCheckedCount > 0 {
					_stat(String.localized("%lld not checked", arguments: _checker.notCheckedCount), color: .secondary)
				}
			}

			Toggle(isOn: $_checkOnline) {
				Label(.localized("Ask Apple (OCSP)"), systemImage: "network")
			}
			.disabled(_checker.isRunning)

			Button {
				Task { await _checker.checkAll(online: _checkOnline) }
			} label: {
				Label(.localized("Check Again"), systemImage: "arrow.triangle.2.circlepath")
			}
			.disabled(_checker.isRunning)
		} footer: {
			Text(.localized("Profile metadata is read on-device. OCSP sends certificate identifiers to the responder; an unavailable answer stays Unknown rather than being reported as good."))
		}
	}

	@ViewBuilder
	private var _progressSection: some View {
		Section {
			VStack(alignment: .leading, spacing: 8) {
				ProgressView(value: Double(_checker.checkedCount), total: Double(max(1, _checker.totalCount)))
				Text(String.localized("Checking %lld of %lld…", arguments: _checker.checkedCount, _checker.totalCount))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}
	}

	@ViewBuilder
	private var _resultsSection: some View {
		ForEach(_checker.results) { result in
			Section {
				LabeledContent(.localized("Status")) {
					Text(result.statusTitle)
						.foregroundStyle(result.statusColor)
				}

				if let days = result.daysRemaining {
					LabeledContent(.localized("Days Remaining"), value: "\(days)")
				}
				if let expiry = result.expiryDate {
					LabeledContent(.localized("Expires"), value: expiry.formatted(date: .abbreviated, time: .omitted))
				}
				LabeledContent(.localized("Team"), value: result.teamID)
				LabeledContent(.localized("PPQ"), value: result.isPPQLess
					? String.localized("PPQLess")
					: String.localized("PPQ"))
				LabeledContent(.localized("JIT"), value: result.supportsJIT
					? String.localized("Supported")
					: String.localized("Not supported"))

				if !result.detail.isEmpty {
					Text(result.detail)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} header: {
				Label(result.name, systemImage: result.statusIcon)
					.foregroundStyle(result.statusColor)
			}
		}
	}

	private func _stat(_ title: String, color: Color) -> some View {
		Text(title)
			.font(.caption.weight(.semibold))
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(color.opacity(0.15), in: Capsule())
			.foregroundStyle(color)
	}
}
