//
//  CertificateCellView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 16.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct CertificatesCellView: View {
	@State var data: Certificate?
	
	@ObservedObject var cert: CertificatePair
	@ObservedObject private var statusManager = CertificateStatusManager.shared
	/// The app being signed, when this cell is shown in a signing context. Nil in Settings,
	/// where there is no app to compare against. Declared last so the memberwise
	/// initializer takes it after `cert`, which is how every call site passes it.
	var target: ProfileCompatibility.Target?

	// MARK: Body
	var body: some View {
		VStack(spacing: 6) {
			let title = {
				var title = cert.nickname ?? data?.Name ?? .localized("Unknown")
				
				if let getTaskAllow = data?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
					title = "🐞 \(title)"
				}
				
				return title
			}()
			
			NBTitleWithSubtitleView(
				title: title,
				subtitle: data?.AppIDName ?? .localized("Unknown")
			)
			
			_certInfoPill(data: cert)
		}
		.frame(height: 80)
		.contentTransition(.opacity)
		.frame(maxWidth: .infinity, alignment: .leading)
		.onAppear {
			withAnimation {
				data = Storage.shared.getProvisionFileDecoded(for: cert)
			}
		}
		.task(id: cert.uuid ?? cert.objectID.uriRepresentation().absoluteString) {
			statusManager.refreshStatusIfNeeded(for: cert)
		}
	}
}

// MARK: - Extension: View
extension CertificatesCellView {
	@ViewBuilder
	private func _certInfoPill(data: CertificatePair) -> some View {
		let pillItems = _buildPills(from: data)
		HStack(spacing: 6) {
			ForEach(pillItems.indices, id: \.hashValue) { index in
				let pill = pillItems[index]
				NBPillView(
					title: pill.title,
					icon: pill.icon,
					color: pill.color,
					index: index,
					count: pillItems.count
				)
			}
		}
	}
	
	private func _buildPills(from cert: CertificatePair) -> [NBPillItem] {
		var pills: [NBPillItem] = []
		// Expiry, the revocation record and the age of the last check, weighed together: a
		// cached "verified" must not outlive the certificate or the evidence behind it.
		let status = statusManager.assessment(for: cert).status

		pills.append(
			NBPillItem(
				title: status.title,
				icon: status.icon,
				color: status.color
			)
		)

		// PPQLess (green) = distribution profile Apple can't revoke through PPQ.
		// PPQ (orange) = development profile: revocable, but the only kind JIT works on.
		let ppq = cert.ppqBadge
		pills.append(NBPillItem(title: ppq.title, icon: ppq.icon, color: ppq.color))

		if let info = cert.expiration?.expirationInfo() {
			pills.append(NBPillItem(
				title: info.formatted,
				icon: info.icon,
				color: info.color
			))
		}

		// "Can this sign this app?" — only answerable while picking a certificate for an app.
		if let target, let data {
			let verdict = ProfileCompatibility.verdict(profile: data, target: target)
			pills.append(NBPillItem(
				title: verdict.title,
				icon: _compatibilityIcon(for: verdict),
				color: _compatibilityColor(for: verdict)
			))
		}
		
		return pills
	}

	private func _compatibilityIcon(for verdict: ProfileCompatibility.Verdict) -> String {
		switch verdict {
		case .covers:
			"checkmark.seal.fill"
		case .wildcard:
			"asterisk.circle.fill"
		case .unusable:
			"xmark.seal.fill"
		case .unknown:
			"questionmark.circle"
		}
	}

	private func _compatibilityColor(for verdict: ProfileCompatibility.Verdict) -> Color {
		switch verdict {
		case .covers:
			.green
		case .wildcard:
			.teal
		case .unusable:
			.red
		case .unknown:
			.secondary
		}
	}
}
