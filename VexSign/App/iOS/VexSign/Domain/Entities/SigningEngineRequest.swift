import Foundation

/// Inputs owned by one signing run; passwords are never diagnostic metadata.
struct SigningEngineRequest: Equatable {
	/// Path to the `.app` bundle that is signed in place.
	var appPath: String
	/// Provisioning profile to embed.
	var provisionPath: String = ""
	/// `.p12` identity the bundle is signed with.
	var p12Path: String = ""
	var p12Password: String = ""
	/// Entitlements the identity is allowed to grant. Empty falls back to the profile's.
	var entitlementsPath: String = ""
	/// Optional `CFBundleIdentifier` / display name / version rewrites.
	var customIdentifier: String = ""
	var customName: String = ""
	var customVersion: String = ""
	/// Ad-hoc signing: the engine signs without an identity.
	var isAdHoc: Bool = false
	/// User intent, straight from `Options.removeProvisioning`: leave no profile behind.
	var removeProvisioning: Bool = false
	/// Profiles for individual nested bundles: bundle identifier → profile path. A nested
	/// bundle that is not listed is signed with `provisionPath`, as before.
	var nestedProvisionPaths: [String: String] = [:]
}
