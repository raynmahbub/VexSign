//
//  PerAppUpdateRulesView.swift
//  VexSign
//
//  Editor for one app's update rules: disable updates, ignore a version,
//  ignore/prefer a source, pin a signing certificate and preserve custom
//  signing options across updates. Presented as a sheet from the Updates tab.
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import CoreData

struct PerAppUpdateRulesView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var store = PerAppUpdateRulesStore.shared

	let appName: String
	let bundleID: String
	let currentVersion: String?

	@State private var rule = PerAppUpdateRule()

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var sources: FetchedResults<AltSource>

	@FetchRequest(entity: CertificatePair.entity(), sortDescriptors: [])
	private var certificates: FetchedResults<CertificatePair>

	var body: some View {
		NBNavigationView(.localized("Update Rules"), displayMode: .inline) {
			NBList(.localized("Update Rules")) {
				NBSection(.localized("App")) {
					VStack(alignment: .leading, spacing: 4) {
						Text(appName)
							.font(.headline)
						Text(verbatim: bundleID)
							.font(.caption.monospaced())
							.foregroundStyle(.secondary)
							.textSelection(.enabled)
					}
					.accessibilityElement(children: .combine)
				}

				NBSection(.localized("Updates")) {
					Toggle(isOn: $rule.disableUpdates) {
						Label(.localized("Disable Updates"), systemImage: "bell.slash.fill")
					}
					.tint(Color.userTint)

				if !rule.disableUpdates {
					Toggle(isOn: ignoreVersionOn) {
							Label(.localized("Ignore This Version"), systemImage: "eye.slash")
						}
						.tint(Color.userTint)
						if rule.ignoredVersion != nil, let version = rule.ignoredVersion {
							Text(verbatim: String.localized("Version %@ is ignored; newer versions still appear.", arguments: version))
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
				} footer: {
					Text(.localized("Disabled apps never appear in update checks, the badge or Update All. Ignoring a version only skips that exact release."))
				}

				NBSection(.localized("Repositories")) {
					Picker(.localized("Preferred Source"), selection: preferredSourceBinding) {
						Text(.localized("Source Priority")).tag("")
						ForEach(Array(sources), id: \.objectID) { source in
							Text(source.name ?? .localized("Unknown")).tag(source.identifier ?? "")
						}
					}
					.pickerStyle(.menu)

					Picker(.localized("Ignore Source"), selection: ignoredSourceBinding) {
						Text(.localized("None")).tag("")
						ForEach(Array(sources), id: \.objectID) { source in
							Text(source.name ?? .localized("Unknown")).tag(source.identifier ?? "")
						}
					}
					.pickerStyle(.menu)
				} footer: {
					Text(.localized("When several repositories publish this app, the preferred source wins over the general source priority. The ignored source never triggers an update."))
				}

				NBSection(.localized("Signing")) {
					Picker(.localized("Certificate"), selection: pinnedCertificateBinding) {
						Text(.localized("Default")).tag("")
						ForEach(Array(certificates), id: \.objectID) { cert in
							Text(cert.nickname ?? cert.uuid ?? .localized("Certificate")).tag(cert.uuid ?? "")
						}
					}
					.pickerStyle(.menu)

					Toggle(isOn: $rule.preserveSigningOptions) {
						Label(.localized("Preserve Signing Options"), systemImage: "paintbrush")
					}
					.tint(Color.userTint)
				} footer: {
					Text(.localized("Updates of this app are signed with the pinned certificate. Custom signing options (name, identifier, tweaks) carry over to the new version."))
				}

				Button(role: .destructive) {
					store.removeRule(forBundleID: bundleID)
					dismiss()
				} label: {
					Label(.localized("Reset to Defaults"), systemImage: "arrow.counterclockwise")
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button(.localized("Cancel")) { dismiss() }
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button(.localized("Save")) {
						store.setRule(rule, forBundleID: bundleID)
						dismiss()
					}
					.font(.body.weight(.semibold))
					.disabled(rule.isEmpty && store.rule(forBundleID: bundleID).isEmpty)
				}
			}
			.onAppear {
				rule = store.rule(forBundleID: bundleID)
			}
		}
	}

	// MARK: - Bindings

	/// Toggle representation of "ignore the currently offered version".
	private var ignoreVersionOn: Binding<Bool> {
		Binding(
			get: { rule.ignoredVersion != nil && !rule.ignoredVersion!.isEmpty },
			set: { on in
				rule.ignoredVersion = on ? (currentVersion ?? "1.0") : nil
			}
		)
	}

	private var preferredSourceBinding: Binding<String> {
		Binding(
			get: { rule.preferredSourceID ?? "" },
			set: { rule.preferredSourceID = $0.isEmpty ? nil : $0 }
		)
	}

	private var ignoredSourceBinding: Binding<String> {
		Binding(
			get: { rule.ignoredSourceID ?? "" },
			set: { rule.ignoredSourceID = $0.isEmpty ? nil : $0 }
		)
	}

	private var pinnedCertificateBinding: Binding<String> {
		Binding(
			get: { rule.pinnedCertificateUUID ?? "" },
			set: { rule.pinnedCertificateUUID = $0.isEmpty ? nil : $0 }
		)
	}
}
