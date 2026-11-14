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
	/// Explicit component-specific authorized entitlements; device signing has no profile-template fallback.
	var entitlementsPath: String = ""
	/// Optional `CFBundleIdentifier` / display name / version rewrites.
	var customIdentifier: String = ""
	var customName: String = ""
	var customVersion: String = ""
	/// Ad-hoc signing: the engine signs without an identity.
	var isAdHoc: Bool = false
	/// User intent, straight from `Options.removeProvisioning`: leave no profile behind.
	var removeProvisioning: Bool = false
	/// Profiles for individual nested bundles: bundle identifier → profile path.
    /// Device signing supplies explicit assets for every profile-bound component.
	var nestedProvisionPaths: [String: String] = [:]
    struct NestedAsset: Equatable {
        let provisionPath: String
        let p12Path: String
        let password: String
        let entitlementsPath: String
    }
    /// Run-owned inputs only. Never encode these into history or saved options.
    var nestedAssets: [String: NestedAsset] = [:]
}
