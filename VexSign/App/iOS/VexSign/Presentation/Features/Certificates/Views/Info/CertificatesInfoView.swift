//
//  CertificatesInfoView.swift
//  VexSign
//
//  Created by VexSign Contributors on 20.04.2025.
//

import SwiftUI
import UniformTypeIdentifiers
import NimbleViews
import NimbleExtensions

// MARK: - View
struct CertificatesInfoView: View {
    @EnvironmentObject var services: AppContainer
	@Environment(\.dismiss) var dismiss
	@State var data: Certificate?
	@State private var _additionalProfiles: [AdditionalProfileRecord] = []
	@State private var _isImportingProfile = false
	@State private var _profilePendingRemoval: AdditionalProfileRecord?
	
	var cert: CertificateRecord
	
	// MARK: Body
    var body: some View {
		NBNavigationView(cert.nickname ?? "", displayMode: .inline) {
			Form {
				Section {} header: {
					Image("Cert")
						.resizable()
						.scaledToFit()
						.frame(width: 107, height: 107)
						.frame(maxWidth: .infinity, alignment: .center)
				}
				
				if let data {
					_infoSection(data: data)
					_entitlementsSection(data: data)
					_miscSection(data: data)
				}

				_additionalProfilesSection()
				
				Section {
					Button(.localized("Export Certificate"), systemImage: "square.and.arrow.up") {
						services.certificates.export(cert)
					}
				}
			}
			.toolbar {
				NBToolbarButton(role: .close)
			}
		}
		.onAppear {
			data = cert.profile
			_additionalProfiles = services.certificates.additionalProfiles(cert)
		}
		.fileImporter(
			isPresented: $_isImportingProfile,
			allowedContentTypes: [UTType(filenameExtension: "mobileprovision") ?? .data],
			allowsMultipleSelection: false
		) { result in
			_importProfile(result)
		}
		.confirmationDialog(
			String.localized("Remove this profile?"),
			isPresented: Binding(
				get: { _profilePendingRemoval != nil },
				set: { if !$0 { _profilePendingRemoval = nil } }
			),
			titleVisibility: .visible
		) {
			Button(.localized("Remove"), role: .destructive) {
				if let entry = _profilePendingRemoval { _removeProfile(entry) }
				_profilePendingRemoval = nil
			}
			Button(.localized("Cancel"), role: .cancel) { _profilePendingRemoval = nil }
		} message: {
			Text(.localized("Extensions that relied on this profile will no longer be covered. The profile file is deleted from this certificate."))
		}
    }
}

// MARK: - Extension: Additional profiles
extension CertificatesInfoView {
	@ViewBuilder
	private func _additionalProfilesSection() -> some View {
		Section {
			ForEach(_additionalProfiles) { entry in
				VStack(alignment: .leading, spacing: 2) {
					Text(entry.name)
					Text(entry.pattern)
						.font(.caption)
						.foregroundStyle(.secondary)
					if entry.isExpired {
						Text(.localized("Expired"))
							.font(.caption)
							.foregroundStyle(.red)
					}
				}
				.swipeActions(edge: .trailing, allowsFullSwipe: false) {
					Button(role: .destructive) {
						_profilePendingRemoval = entry
					} label: {
						Label(.localized("Remove"), systemImage: "trash")
					}
				}
			}

			Button(.localized("Add Extension Profile"), systemImage: "plus") {
				_isImportingProfile = true
			}
		} header: {
			Text(.localized("Extension Profiles"))
		} footer: {
			Text(.localized("Every retained application and extension needs a compatible profile. Imported profiles are evaluated with the available identities; certificate membership and an accessible matching private key are required. Adding a profile does not bypass identifier, capability or device checks."))
		}
	}

	private func _importProfile(_ result: Result<[URL], Error>) {
		let source: URL
		switch result {
		case .success(let urls):
			guard let first = urls.first else { return }
			source = first
		case .failure(let error):
			Toast.error(error.localizedDescription)
			return
		}


		do {
			try services.certificates.addProfile(source, to: cert)
			_additionalProfiles = services.certificates.additionalProfiles(cert)
			Toast.success(.localized("Extension profile added"))
		} catch {
			Toast.error(error.localizedDescription)
		}
	}

	private func _removeProfile(_ entry: AdditionalProfileRecord) {
		do {
			try services.certificates.removeProfile(entry, from: cert)
			_additionalProfiles = services.certificates.additionalProfiles(cert)
		} catch {
			Toast.error(error.localizedDescription)
		}
	}
}

// MARK: - Extension: View
extension CertificatesInfoView {
	@ViewBuilder
	private func _infoSection(data: Certificate) -> some View {
		NBSection(.localized("Info")) {
			_info(.localized("Name"), description: data.Name)
			_info(.localized("AppID Name"), description: data.AppIDName)
			_info(.localized("Team Name"), description: data.TeamName)
		}
		
		Section {
			_info(.localized("Expires"), description: data.ExpirationDate.expirationInfo().formatted)
				.foregroundStyle(data.ExpirationDate.expirationInfo().color)
			
			_info(.localized("Revoked"), description: cert.revoked ? "✓" : "✗")
			
			_info(.localized("Profile Type"), description: data.profileType.title)

			// Green PPQLess / orange PPQ, matching the badge in the certificate list.
			_info(.localized("PPQ Status"), description: cert.ppqBadge.title)
				.foregroundStyle(cert.ppqBadge.color)

			_info(.localized("JIT Support"), description: cert.supportsJIT
				? String.localized("Supported")
				: String.localized("Not supported (PPQLess)"))
		} footer: {
			Text(.localized("PPQLess profiles are distribution profiles Apple can't revoke through the provisioning-profile query. JIT needs `get-task-allow`, which only PPQ (development) profiles grant."))
		}
	}
	
	@ViewBuilder
	private func _entitlementsSection(data: Certificate) -> some View {
		if let entitlements = data.Entitlements {
			Section {
				NavigationLink(.localized("View Entitlements")) {
					CertificatesInfoEntitlementView(entitlements: entitlements)
				}
			}
		}
	}
	
	@ViewBuilder
	private func _miscSection(data: Certificate) -> some View {
		NBSection(.localized("Misc")) {
			_disclosure(.localized("Platform"), keys: data.Platform)
			
			if let all = data.ProvisionsAllDevices {
				_info(.localized("Provision All Devices"), description: all.description)
			}
			
			if let devices = data.ProvisionedDevices {
				_disclosure(.localized("Provisioned Devices"), keys: devices)
			}
			
			_disclosure(.localized("Team Identifiers"), keys: data.TeamIdentifier)
			
			if let prefix = data.ApplicationIdentifierPrefix {
				_disclosure(.localized("Identifier Prefix"), keys: prefix)
			}
		}
	}
	
	@ViewBuilder
	private func _info(_ title: String, description: String) -> some View {
		LabeledContent(title) {
			Text(description)
		}
		.copyableText(description)
	}
	
	@ViewBuilder
	private func _disclosure(_ title: String, keys: [String]) -> some View {
		DisclosureGroup(title) {
			ForEach(keys, id: \.self) { key in
				Text(key)
					.foregroundStyle(.secondary)
					.copyableText(key)
			}
		}
	}
}
