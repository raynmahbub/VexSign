//
//  NamedSigningProfileStore.swift
//  VexSign
//
//  Named, shareable signing presets on top of the per-bundle SigningProfileStore.
//  "Games + ElleKit" can be applied to a batch or exported as JSON.
//

import Foundation

final class NamedSigningProfileStore: ObservableObject {
	static let shared = NamedSigningProfileStore()

	private static let defaultsKey = "VexSign.namedSigningProfiles"

	@Published private(set) var profiles: [NamedSigningProfile] = []

	private init() {
		profiles = Self.load()
	}

	func save(_ profile: NamedSigningProfile) {
		let profile = profile.withoutOneShotFiles()
		if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
			profiles[index] = profile
		} else {
			profiles.insert(profile, at: 0)
		}
		persist()
	}

	func remove(id: String) {
		profiles.removeAll { $0.id == id }
		persist()
	}

	func exportJSON() -> Data? {
		try? JSONEncoder().encode(profiles.map { $0.withoutOneShotFiles() })
	}

	func importJSON(_ data: Data) throws {
		let incoming = try JSONDecoder().decode([NamedSigningProfile].self, from: data)
			.map { $0.withoutOneShotFiles() }
		for profile in incoming {
			if let index = profiles.firstIndex(where: { $0.id == profile.id || $0.name == profile.name }) {
				profiles[index] = profile
			} else {
				profiles.append(profile)
			}
		}
		persist()
	}

	func certificate(for profile: NamedSigningProfile) -> CertificatePair? {
		SigningProfileStore.shared.certificate(for: SigningProfile(
			bundleID: profile.id,
			options: profile.options,
			certificateUUID: profile.certificateUUID,
			savedAt: profile.savedAt
		))
	}

	private func persist() {
		if let data = try? JSONEncoder().encode(profiles) {
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
	}

	private static func load() -> [NamedSigningProfile] {
		guard
			let data = UserDefaults.standard.data(forKey: defaultsKey),
			let decoded = try? JSONDecoder().decode([NamedSigningProfile].self, from: data)
		else { return [] }
		return decoded.map { $0.withoutOneShotFiles() }
	}
}
