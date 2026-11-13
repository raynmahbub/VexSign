//
//  SigningProfilesView.swift
//  VexSign
//

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers
import NimbleExtensions

struct SigningProfilesView: View {
	@ObservedObject private var store = NamedSigningProfileStore.shared
	@State private var _newName = ""
	@State private var _isNaming = false

	var body: some View {
		NBList(.localized("Signing Profiles")) {
			Section {
				Button {
					_newName = ""
					_isNaming = true
				} label: {
					Label(.localized("Save Current Options as Profile"), systemImage: "plus")
				}

				Button {
					if let data = store.exportJSON() {
						let url = FileManager.default.temporaryDirectory.appendingPathComponent("VexSign-profiles.json")
						try? data.write(to: url)
						UIActivityViewController.show(activityItems: [url])
					}
				} label: {
					Label(.localized("Export Profiles"), systemImage: "square.and.arrow.up")
				}
				.disabled(store.profiles.isEmpty)

				Button {
					DocumentPicker.open([.json], multiple: false) { urls in
						guard let url = urls.first, let data = try? Data(contentsOf: url) else { return }
						do {
							try store.importJSON(data)
							Toast.success(.localized("Profiles imported"), systemImage: "checkmark")
						} catch {
							Toast.error(error.localizedDescription, duration: .long)
						}
					}
				} label: {
					Label(.localized("Import Profiles"), systemImage: "square.and.arrow.down")
				}
			} footer: {
				Text(.localized("Named presets reuse the same Options snapshot as Re-sign with last settings. Export is a JSON file you can share with another install."))
			}

			if !store.profiles.isEmpty {
				Section {
					ForEach(store.profiles) { profile in
						VStack(alignment: .leading, spacing: 2) {
							Text(profile.name)
								.font(.body.weight(.medium))
							Text(verbatim: profile.savedAt.formatted(date: .abbreviated, time: .shortened))
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						.swipeActions(edge: .trailing, allowsFullSwipe: false) {
							Button(role: .destructive) {
								store.remove(id: profile.id)
							} label: {
								Label(.localized("Delete"), systemImage: "trash")
							}
						}
					}
				}
			}
		}
		.alert(.localized("Profile Name"), isPresented: $_isNaming) {
			TextField(.localized("Name"), text: $_newName)
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("Save")) {
				let name = _newName.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !name.isEmpty else { return }
				let cert = Storage.shared.getCertificate(for: UserDefaults.standard.integer(forKey: "vexsign.selectedCert"))
				store.save(NamedSigningProfile(
					name: name,
					options: OptionsManager.shared.options,
					certificateUUID: cert?.uuid
				))
			}
		}
	}
}
