//
//  Bundle+versions.swift
//  Loader
//
//  Created by VexSign Contributors on 18.03.2025.
//

import Foundation.NSBundle

extension Bundle {
	/// Get the name of the app
	public var name: String {
		if
			let displayName = object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
			!displayName.isEmpty
		{
			return displayName
		}
		if
			let name = object(forInfoDictionaryKey: "CFBundleName") as? String,
			!name.isEmpty
		{
			return name
		}
		return object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
	}
	
	/// Get the executable name of the app
	public var exec: String {
		let name = _rawInfo("CFBundleExecutable") as? String ?? ""
		if !name.isEmpty, FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(name).path) {
			return name
		}
		return executableURL?.lastPathComponent ?? name
	}

	// Raw plist for keys naming a file: InfoPlist.strings can localize them, and
	// object(forInfoDictionaryKey:) returns that translation.
	private func _rawInfo(_ key: String) -> Any? {
		infoDictionary?[key]
	}
	
	/// Get the "short" version of the app
	public var version: String {
		if let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
			return version
		}
		
		return object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
	}
	
	/// Get the build number of the app
	public var buildNumber: String {
		object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
	}
	
	/// Get the icon of the app
	public var iconFileName: String? {
		if
			let icons = _rawInfo("CFBundleIcons") as? [String: Any],
			let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
			let files = primary["CFBundleIconFiles"] as? [String],
			let name = files.last
		{
			return name
		}
		
		if
			let iPadIcons = _rawInfo("CFBundleIcons~ipad") as? [String: Any],
			let primary = iPadIcons["CFBundlePrimaryIcon"] as? [String: Any],
			let files = primary["CFBundleIconFiles"] as? [String],
			let name = files.last
		{
			return name
		}
		
		if
			let iconFiles = _rawInfo("CFBundleIconFiles") as? [String],
			let name = iconFiles.last ?? iconFiles.first
		{
			return name
		}
		
		if
			let iPhoneIconFiles = _rawInfo("CFBundleIconFiles~iphone") as? [String],
			let name = iPhoneIconFiles.last ?? iPhoneIconFiles.first
		{
			return name
		}
		
		if
			let iPadIconFiles = _rawInfo("CFBundleIconFiles~ipad") as? [String],
			let name = iPadIconFiles.last ?? iPadIconFiles.first
		{
			return name
		}
		
		if let iconFile = _rawInfo("CFBundleIconFile") as? String {
			return iconFile
		}
		
		return nil
	}
}
