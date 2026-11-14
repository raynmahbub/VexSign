import Foundation

struct SigningProfile: Codable, Equatable {
	/// Bundle identifier the profile was captured for (the app's own id, not the PPQ-mangled one).
	let bundleID: String
	/// Full options snapshot — tweaks, entitlements, Info.plist overrides, display name, keychain isolation.
	let options: Options
	/// The `CertificatePair.uuid` used at capture. `nil` means "default / whatever is selected now".
	let certificateUUID: String?
	/// When it was last used, for display in the picker.
	let savedAt: Date
	/// Names, never paths, of the one-time tweak files the captured sign injected.
	///
	/// Those files are staged for one sign and are not kept, so the saved options must not point
	/// at them: replaying a dead staging URL is what made "Re-sign with last settings" and Update
	/// All stop in the Customize step. The names are kept so a replay can say what it left out.
	/// Optional, so a profile saved before this field existed still decodes.
	var oneShotFileNames: [String]? = nil
}
