import Foundation

// MARK: - Options
struct Options: Codable, Equatable, Sendable {
	
	// MARK: Pre Modifications
	
	/// App name
	var appName: String?
	/// App version
	var appVersion: String?
	/// App bundle identifer
	var appIdentifier: String?
	/// App entitlements
	var appEntitlementsFile: URL?
	/// App apparence (i.e. Light/Dark/Default)
	var appAppearance: AppAppearance
	/// App minimum iOS requirement (i.e. iOS 11.0)
	var minimumAppRequirement: MinimumAppRequirement
	/// Signing options
	var signingOption: SigningOption
	
	// MARK: Options
	
	/// Inject path (i.e. `@rpath`)
	var injectPath: InjectPath
	/// Inject folder (i.e. `Frameworks/`)
	var injectFolder: InjectFolder
	/// Random string appended to the app identifier
	var ppqString: String
	/// Protection mode against PPQ
	var ppqProtection: PPQProtection
	/// (Better) protection against PPQ
	var dynamicProtection: Bool
	/// App identifiers list which matches and replaces
	var identifiers: [String: String]
	/// App name list which matches and replaces
	var displayNames: [String: String]
	/// Array of files (`.dylib`, `.deb` ) to extract and inject
	var injectionFiles: [URL]
	/// Explicit, provenance-bearing include/exclude rules for a modification plan.
	/// Empty means the legacy explicit-file flow; when present, a tweak is never
	/// injected into a bundle that no rule selected.
	var injectionConfigurations: [InjectionConfiguration]
	/// Mach-o load paths to remove (i.e. `@executable_path/demo1.dylib`)
	var disInjectionFiles: [String]
	/// App files to remove from (i.e. `Frameworks/CydiaSubstrate.framework`)
	var removeFiles: [String]
	/// If app should have filesharing forcefully enabled
	var fileSharing: Bool
	/// If app should have iTunes filesharing forcefully enabled
	var itunesFileSharing: Bool
	/// If app should have Pro Motion enabled (may not be needed)
	var proMotion: Bool
	/// If app should have Game Mode enabled
	var gameMode: Bool
	/// If app should use fullscreen (iPad mainly)
	var ipadFullscreen: Bool
	/// If app shouldn't have URL Schemes
	var removeURLScheme: Bool
	/// If app should not include a `embedded.mobileprovision` (useful for JB detection)
	var removeProvisioning: Bool
	/// Forcefully rename string files for App name
	var changeLanguageFilesForCustomDisplayName: Bool
	/// If tweaks should be injected into all app extensions (PlugIns and Extensions)
	var injectIntoExtensions: Bool
	/// If app extensions (PlugIns/ and Extensions/) should be stripped from the app bundle.
	/// Defaults to `false` so widget/app extensions are preserved when signing.
	var removeAppExtensions: Bool
	/// When explicitly enabled, removes app extensions the selected profile cannot sign.
	/// Covered extensions, Watch apps, and extensions with unknown coverage are preserved.
	var autoRemoveUnsupportedExtensions: Bool
    /// Nil/true evaluates all imported identities. False restricts to the manually selected identity.
    var automaticallyResolveSigningIdentity: Bool?
    /// Per-component manual choices; valid candidates only, never bypasses.
    var componentSigningPreferences: [String: ComponentSigningPreference]?
	/// Gives each signed app a keychain group derived from its bundle id so apps can't read each other's entries
	var keychainIsolation: Bool
	/// Signs with JIT entitlements (`dynamic-codesigning`). Only PPQ certificates can carry them.
	var enableJIT: Bool
	/// Injects the bundled fix that makes the document picker import files into the app's own container
	var fixFilePicker: Bool
	/// Resolved managed-tweak injections for this sign; per-sign working copy only. Optional so old saved options decode.
	var tweakInjections: [TweakInjectionSpec]?
	/// Raw Info.plist overrides for this sign, kept as an XML plist blob so any value type survives.
	var infoPlistOverrides: Data?
	/// Info.plist keys stripped from the bundle for this sign.
	var infoPlistRemovals: [String]?
	/// Removes the legacy MinimumOSVersion gate from the signed bundle.
	var removeMinimumOSVersion: Bool

	/// Strips non-target architectures (armv7, x86_64, etc.) from Mach-O binaries down to ARM64
	var thinMachOBinaries: Bool

	// MARK: Experiments
	
	/// Modifies app to support liquid glass
	var experiment_supportLiquidGlass: Bool
	/// Modifies app to disable liquid glass
	var experiment_disableLiquidGlass: Bool
	/// Modifies application to use ElleKit instead of CydiaSubstrate
	var experiment_replaceSubstrateWithEllekit: Bool
	
	// MARK: Post Modifications
	
	var post_installAppAfterSigned: Bool
	/// This will delete your imported application after signing, to save on using unneeded space.
	var post_deleteAppAfterSigned: Bool

	// MARK: - Defaults
	static let defaultOptions = Options(
		
		// MARK: Pre Modifications
		
		appAppearance: .default,
		minimumAppRequirement: .default,
		signingOption: .default,
		
		// MARK: Options
		
		injectPath: .executable_path,
		injectFolder: .frameworks,
		ppqString: "AN0X1",
		ppqProtection: .disabled,
		dynamicProtection: false,
		identifiers: [:],
		displayNames: [:],
		injectionFiles: [],
		injectionConfigurations: [],
		disInjectionFiles: [],
		removeFiles: [],
		fileSharing: false,
		itunesFileSharing: false,
		proMotion: false,
		gameMode: false,
		ipadFullscreen: false,
		removeURLScheme: false,
		removeProvisioning: false,
		changeLanguageFilesForCustomDisplayName: false,
		injectIntoExtensions: false,
		removeAppExtensions: false,
		autoRemoveUnsupportedExtensions: false,
		keychainIsolation: false,
		enableJIT: false,
		fixFilePicker: false,
		removeMinimumOSVersion: false,

		// MARK: Experiments
		
		thinMachOBinaries: false,
		experiment_supportLiquidGlass: false,
		experiment_disableLiquidGlass: false,
		experiment_replaceSubstrateWithEllekit: false,
		
		// MARK: Post Modifications
		
		post_installAppAfterSigned: true,
		post_deleteAppAfterSigned: false
	)
	
	// MARK: duplicate values are not recommended!

	enum AppAppearance: String, Codable, CaseIterable, Sendable {
		case `default`
		case light = "Light"
		case dark = "Dark"


	}

	enum MinimumAppRequirement: String, Codable, CaseIterable, Sendable {
		case `default`
		case v16 = "16.0"
		case v15 = "15.0"
		case v14 = "14.0"
		case v13 = "13.0"
		case v12 = "12.0"


	}
	
	enum SigningOption: String, Codable, CaseIterable, Sendable {
		case `default`
		case onlyModify


	}
	
	enum InjectPath: String, Codable, CaseIterable, Sendable {
		case executable_path = "@executable_path"
		case rpath = "@rpath"
	}
	
	enum InjectFolder: String, Codable, CaseIterable, Sendable {
		case root = "/"
		case frameworks = "/Frameworks/"
	}

	enum PPQProtection: String, Codable, CaseIterable, Sendable {
		case disabled
		/// VexSign method: append ppqString to the untouched identifier
		case `default`
		/// Vex method: prefix with "vex", replace known keywords, append ppqString
		case vex = "Vex"


	}
	
	/// Default random value for `ppqString`
	static func randomString() -> String {
		String((0..<6).compactMap { _ in UUID().uuidString.randomElement() })
	}
}

// MARK: - Tolerant decoding
// A field missing from older saved data defaults on its own instead of failing the whole decode.
extension Options {
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = Options.defaultOptions

		appName = try c.decodeIfPresent(String.self, forKey: .appName)
		appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
		appIdentifier = try c.decodeIfPresent(String.self, forKey: .appIdentifier)
		appEntitlementsFile = try c.decodeIfPresent(URL.self, forKey: .appEntitlementsFile)
		appAppearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appAppearance) ?? d.appAppearance
		minimumAppRequirement = try c.decodeIfPresent(MinimumAppRequirement.self, forKey: .minimumAppRequirement) ?? d.minimumAppRequirement
		signingOption = try c.decodeIfPresent(SigningOption.self, forKey: .signingOption) ?? d.signingOption
		injectPath = try c.decodeIfPresent(InjectPath.self, forKey: .injectPath) ?? d.injectPath
		injectFolder = try c.decodeIfPresent(InjectFolder.self, forKey: .injectFolder) ?? d.injectFolder
		ppqString = try c.decodeIfPresent(String.self, forKey: .ppqString) ?? d.ppqString
		ppqProtection = (try? c.decode(PPQProtection.self, forKey: .ppqProtection)) ?? d.ppqProtection // try? ok: tolerate an unknown persisted optional field; signing admission and verification still run
		dynamicProtection = try c.decodeIfPresent(Bool.self, forKey: .dynamicProtection) ?? d.dynamicProtection
		identifiers = try c.decodeIfPresent([String: String].self, forKey: .identifiers) ?? d.identifiers
		displayNames = try c.decodeIfPresent([String: String].self, forKey: .displayNames) ?? d.displayNames
		injectionFiles = try c.decodeIfPresent([URL].self, forKey: .injectionFiles) ?? d.injectionFiles
		injectionConfigurations = try c.decodeIfPresent([InjectionConfiguration].self, forKey: .injectionConfigurations) ?? d.injectionConfigurations
		disInjectionFiles = try c.decodeIfPresent([String].self, forKey: .disInjectionFiles) ?? d.disInjectionFiles
		removeFiles = try c.decodeIfPresent([String].self, forKey: .removeFiles) ?? d.removeFiles
		fileSharing = try c.decodeIfPresent(Bool.self, forKey: .fileSharing) ?? d.fileSharing
		itunesFileSharing = try c.decodeIfPresent(Bool.self, forKey: .itunesFileSharing) ?? d.itunesFileSharing
		proMotion = try c.decodeIfPresent(Bool.self, forKey: .proMotion) ?? d.proMotion
		gameMode = try c.decodeIfPresent(Bool.self, forKey: .gameMode) ?? d.gameMode
		ipadFullscreen = try c.decodeIfPresent(Bool.self, forKey: .ipadFullscreen) ?? d.ipadFullscreen
		removeURLScheme = try c.decodeIfPresent(Bool.self, forKey: .removeURLScheme) ?? d.removeURLScheme
		removeProvisioning = try c.decodeIfPresent(Bool.self, forKey: .removeProvisioning) ?? d.removeProvisioning
		changeLanguageFilesForCustomDisplayName = try c.decodeIfPresent(Bool.self, forKey: .changeLanguageFilesForCustomDisplayName) ?? d.changeLanguageFilesForCustomDisplayName
		injectIntoExtensions = try c.decodeIfPresent(Bool.self, forKey: .injectIntoExtensions) ?? d.injectIntoExtensions
		removeAppExtensions = try c.decodeIfPresent(Bool.self, forKey: .removeAppExtensions) ?? d.removeAppExtensions
		autoRemoveUnsupportedExtensions = try c.decodeIfPresent(Bool.self, forKey: .autoRemoveUnsupportedExtensions) ?? d.autoRemoveUnsupportedExtensions
        automaticallyResolveSigningIdentity = try c.decodeIfPresent(Bool.self, forKey: .automaticallyResolveSigningIdentity)
        componentSigningPreferences = try c.decodeIfPresent([String: ComponentSigningPreference].self, forKey: .componentSigningPreferences)
		keychainIsolation = try c.decodeIfPresent(Bool.self, forKey: .keychainIsolation) ?? d.keychainIsolation
		enableJIT = try c.decodeIfPresent(Bool.self, forKey: .enableJIT) ?? d.enableJIT
		fixFilePicker = try c.decodeIfPresent(Bool.self, forKey: .fixFilePicker) ?? d.fixFilePicker
		// Optional per-sign blobs may be stale; discard those fields, not the whole saved preset.
		tweakInjections = try? c.decode([TweakInjectionSpec].self, forKey: .tweakInjections) // try? ok: tolerate an unknown persisted optional field; signing admission and verification still run
		infoPlistOverrides = try? c.decode(Data.self, forKey: .infoPlistOverrides) // try? ok: tolerate an unknown persisted optional field; signing admission and verification still run
		infoPlistRemovals = try? c.decode([String].self, forKey: .infoPlistRemovals) // try? ok: tolerate an unknown persisted optional field; signing admission and verification still run
		removeMinimumOSVersion = try c.decodeIfPresent(Bool.self, forKey: .removeMinimumOSVersion) ?? d.removeMinimumOSVersion
		thinMachOBinaries = try c.decodeIfPresent(Bool.self, forKey: .thinMachOBinaries) ?? d.thinMachOBinaries
		experiment_supportLiquidGlass = try c.decodeIfPresent(Bool.self, forKey: .experiment_supportLiquidGlass) ?? d.experiment_supportLiquidGlass
		experiment_disableLiquidGlass = try c.decodeIfPresent(Bool.self, forKey: .experiment_disableLiquidGlass) ?? d.experiment_disableLiquidGlass
		experiment_replaceSubstrateWithEllekit = try c.decodeIfPresent(Bool.self, forKey: .experiment_replaceSubstrateWithEllekit) ?? d.experiment_replaceSubstrateWithEllekit
		post_installAppAfterSigned = try c.decodeIfPresent(Bool.self, forKey: .post_installAppAfterSigned) ?? d.post_installAppAfterSigned
		post_deleteAppAfterSigned = try c.decodeIfPresent(Bool.self, forKey: .post_deleteAppAfterSigned) ?? d.post_deleteAppAfterSigned
	}
}


extension Options {
    var effectiveAppIdentifier: String? {
        let trimmed = appIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
    func withoutPerAppFields() -> Options {
        var result = self
        result.appName = nil; result.appIdentifier = nil; result.appVersion = nil; result.tweakInjections = nil
        // Structured rules are per-run, tied to the inspected package versions.
        result.injectionConfigurations = []
        result.componentSigningPreferences = nil
        return result
    }
    mutating func resetPerApp(autoInject: [TweakInjectionSpec]) {
        appName = nil; appIdentifier = nil; appVersion = nil; appEntitlementsFile = nil
        infoPlistOverrides = nil; infoPlistRemovals = nil; tweakInjections = autoInject
        componentSigningPreferences = nil
    }
}
