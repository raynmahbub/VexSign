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
