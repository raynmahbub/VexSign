//
//  UnattendedSigningGrantSection.swift
//  VexSign
//
//  Where the user allows, sees and ends background signing.
//

import SwiftUI
import NimbleExtensions

struct UnattendedSigningGrantSection: View {
	@AppStorage("vexsign.selectedCert") private var _selectedCertificate: Int = 0
	@State private var _grant: UnattendedSigningGrant?
	@State private var _pendingLifetime: UnattendedSigningGrant.Lifetime?
	@State private var _now = Date()

	private var _certificate: CertificatePair? {
		Storage.shared.getCertificate(for: _selectedCertificate)
	}

	private var _decision: UnattendedSigningGrant.Decision {
		UnattendedSigningGrant.decision(
			grant: _grant,
			scope: .signAndQueueUpdates,
			certificateUUID: _certificate?.uuid,
			now: _now
		)
	}

	var body: some View {
		Section {
			VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
				Text(_decision.isAuthorized
					? String.localized("Allowed")
					: String.localized("Not allowed"))
					.font(.subheadline.weight(.semibold))
				Text(_decision.explanation).font(.caption).foregroundStyle(.secondary)
				if _decision.isAuthorized, let grant = _grant {
					Text(String.localized("Until %@", arguments: grant.expiresAt.formatted(date: .abbreviated, time: .shortened)))
						.font(.caption).foregroundStyle(.secondary)
				}
			}
			.accessibilityElement(children: .combine)

			if _certificate?.uuid == nil {
				Text(String.localized("Select a certificate before allowing background signing."))
					.font(.caption).foregroundStyle(.secondary)
			} else {
				Menu(_decision.isAuthorized
					? String.localized("Allow again for…")
					: String.localized("Allow background signing for…")) {
					ForEach(UnattendedSigningGrant.Lifetime.allCases) { lifetime in
						Button(lifetime.title) { _pendingLifetime = lifetime }
					}
				}
			}

			if _decision.isAuthorized {
				Button(String.localized("Turn Off Background Signing"), role: .destructive) {
					UnattendedSigningGrantStore.revoke()
					_reload()
				}
			}
		} header: {
			Text(String.localized("Background Signing"))
		} footer: {
			Text(String.localized("Lets scheduled checks sign found updates with the selected certificate while you are not using VexSign. It ends by itself, and you can turn it off at any time. Without it, scheduled checks only notify you. Runs you start yourself are not affected."))
		}
		.confirmationDialog(
			String.localized("Allow background signing?"),
			isPresented: Binding(
				get: { _pendingLifetime != nil },
				set: { if !$0 { _pendingLifetime = nil } }
			),
			titleVisibility: .visible
		) {
			if let lifetime = _pendingLifetime {
				Button(String.localized("Allow for %@", arguments: lifetime.title)) { _issue(lifetime) }
			}
			Button(String.localized("Cancel"), role: .cancel) { _pendingLifetime = nil }
		} message: {
			Text(String.localized("VexSign will be able to sign app updates with the selected certificate in the background. Only this certificate is covered; choosing another one ends the permission."))
		}
		.onAppear { _reload() }
	}

	private func _reload() {
		_now = Date()
		_grant = UnattendedSigningGrantStore.current()
	}

	private func _issue(_ lifetime: UnattendedSigningGrant.Lifetime) {
		_pendingLifetime = nil
		guard let uuid = _certificate?.uuid,
		      let grant = UnattendedSigningGrant.issue(
			scope: .signAndQueueUpdates, certificateUUID: uuid, lifetime: lifetime
		      ) else { return }
		UnattendedSigningGrantStore.save(grant)
		_reload()
	}
}
