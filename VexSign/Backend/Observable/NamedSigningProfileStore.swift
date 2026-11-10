//
//  NamedSigningProfileStore.swift
//  VexSign
//
//  Named, shareable signing presets on top of the per-bundle SigningProfileStore.
//  "Games + ElleKit" can be applied to a batch or exported as JSON.
//

import Foundation

struct NamedSigningProfile: Codable, Identifiable, Equatable {
	var id: String
	var name: String
	var options: Options
	var certificateUUID: String?
	var savedAt: Date

	init(id: String = UUID().uuidString, name: String, options: Options, certificateUUID: String?, savedAt: Date = Date()) {
		self.id = id
		self.name = name
		var snapshot = options
		snapshot.appName = nil
		snapshot.appVersion = nil
		snapshot.appIdentifier = nil
		snapshot.appEntitlementsFile = nil
		// A preset is reused across apps and can be exported, so it never carries the files that
		// were staged for one sign: their URLs point into this device's temporary directory.
		snapshot.injectionFiles = []
		self.options = snapshot
		self.certificateUUID = certificateUUID
		self.savedAt = savedAt
	}

	/// The preset without one-shot tweak files.
	///
	/// Decoding does not go through `init(name:options:...)`, so presets saved by earlier versions
	/// and presets imported from a file can still carry staging URLs. Applying one made the sign
	/// stop in the Customize step, because the files those URLs named were long gone.
	func withoutOneShotFiles() -> NamedSigningProfile {
		guard !options.injectionFiles.isEmpty else { return self }
		var preset = self
		preset.options.injectionFiles = []
		return preset
	}
}

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
		try? JSONEncoder().encode(profiles)
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
