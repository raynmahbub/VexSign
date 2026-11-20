//
//  InfoPlistCommonKeys.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation
import NimbleExtensions

struct InfoPlistCommonKey: Identifiable {
	let key: String
	let value: Any

	var id: String { key }
}

/// Keys worth reaching for when patching an app, grouped the way they're usually needed.
enum InfoPlistCommonKeys {
	static var groups: [(title: String, keys: [InfoPlistCommonKey])] {
		[
			(.localized("Network"), [
				// The ATS escape hatch this list offers is the narrow one: a patched
				// app that talks to a machine on the same network (an AltStore or
				// VexSign server, a sideloaded tool) needs it, and that is what
				// `NSAllowsLocalNetworking` unlocks. `NSAllowsArbitraryLoads` used to
				// sit here and turned off App Transport Security for *every* host in
				// the app being signed, which is a much larger hole than the one the
				// user is trying to open. Anyone who really needs the blanket
				// exception can still type it by hand in the key editor.
				InfoPlistCommonKey(key: "NSAppTransportSecurity", value: ["NSAllowsLocalNetworking": true]),
				InfoPlistCommonKey(key: "NSLocalNetworkUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSBonjourServices", value: [String]()),
				InfoPlistCommonKey(key: "UIRequiresPersistentWiFi", value: true)
			]),
			(.localized("Privacy"), [
				InfoPlistCommonKey(key: "NSCameraUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSMicrophoneUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSPhotoLibraryUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSPhotoLibraryAddUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSLocationWhenInUseUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSLocationAlwaysAndWhenInUseUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSContactsUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSFaceIDUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSBluetoothAlwaysUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSMotionUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSSpeechRecognitionUsageDescription", value: ""),
				InfoPlistCommonKey(key: "NSUserTrackingUsageDescription", value: "")
			]),
			(.localized("Interface"), [
				InfoPlistCommonKey(key: "UIStatusBarHidden", value: true),
				InfoPlistCommonKey(key: "UIViewControllerBasedStatusBarAppearance", value: false),
				InfoPlistCommonKey(key: "UIStatusBarStyle", value: "UIStatusBarStyleDefault"),
				InfoPlistCommonKey(key: "UISupportedInterfaceOrientations", value: [
					"UIInterfaceOrientationPortrait",
					"UIInterfaceOrientationLandscapeLeft",
					"UIInterfaceOrientationLandscapeRight"
				]),
				InfoPlistCommonKey(key: "UISupportedInterfaceOrientations~ipad", value: [
					"UIInterfaceOrientationPortrait",
					"UIInterfaceOrientationPortraitUpsideDown",
					"UIInterfaceOrientationLandscapeLeft",
					"UIInterfaceOrientationLandscapeRight"
				]),
				InfoPlistCommonKey(key: "UIPrerenderedIcon", value: true)
			]),
			(.localized("Capabilities"), [
				InfoPlistCommonKey(key: "LSSupportsOpeningDocumentsInPlace", value: true),
				InfoPlistCommonKey(key: "LSApplicationQueriesSchemes", value: [String]()),
				InfoPlistCommonKey(key: "UIRequiredDeviceCapabilities", value: [String]()),
				InfoPlistCommonKey(key: "UIApplicationSupportsIndirectInputEvents", value: true),
				InfoPlistCommonKey(key: "ITSAppUsesNonExemptEncryption", value: false),
				InfoPlistCommonKey(key: "UIApplicationSceneManifest", value: ["UIApplicationSupportsMultipleScenes": true])
			])
		]
	}
}
