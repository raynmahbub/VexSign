//
//  UTType+ipa.swift
//  VexSign
//
//  Created by VexSign Contributors on 11.04.2025.
//

import UniformTypeIdentifiers

extension UTType {
	static var dylib: UTType {
		.init(filenameExtension: "dylib") ?? .data
	}
	static var deb: UTType {
		.init(filenameExtension: "deb") ?? .data
	}
	static var ipa: UTType {
		.init(filenameExtension: "ipa") ?? .data
	}
	static var tipa: UTType {
		.init(filenameExtension: "tipa") ?? .data
	}
	static var entitlements: UTType {
		.init(filenameExtension: "entitlements", conformingTo: .data) ?? .data
	}
	static var p12: UTType {
		.init(filenameExtension: "p12", conformingTo: .data) ?? .data
	}
	static var mobileProvision: UTType {
		.init(filenameExtension: "mobileprovision", conformingTo: .data) ?? .data
	}
	/// The older `.provisionprofile` spelling Apple's own tooling still emits.
	static var provisionProfile: UTType {
		.init(filenameExtension: "provisionprofile", conformingTo: .data) ?? .data
	}
	/// The PKCS#12 key under the name some exporters give it.
	static var pfx: UTType {
		.init(filenameExtension: "pfx", conformingTo: .data) ?? .data
	}
	static var vexBackup: UTType {
		.init(filenameExtension: "vexbackup", conformingTo: .data) ?? .data
	}

	/// What every package picker offers.
	///
	/// Derived from `PackageArchiveType.pickerExtensions` instead of being written
	/// out at each screen. The lists had drifted: the library offered `.zip`,
	/// onboarding did not (so a zipped app could not be imported from the first
	/// screen a new user sees), and the companion flow offered only `.ipa`. One
	/// source cannot disagree with the importer about what it opens.
	static var packageArchives: [UTType] {
		PackageArchiveType.pickerExtensions.map { extensionName in
			UTType(filenameExtension: extensionName) ?? _fallback(for: extensionName)
		}
	}

	/// What a certificate import offers: either half of the key/profile pair on
	/// its own, or a container holding both. Derived from
	/// `CertificateImportBundle.pickerExtensions`, which is also what decides how
	/// the selection is resolved, so `.pfx` and `.provisionprofile` are reachable
	/// from the screen that already parses them.
	static var certificateBundles: [UTType] {
		CertificateImportBundle.pickerExtensions.map { extensionName in
			UTType(filenameExtension: extensionName) ?? _fallback(for: extensionName)
		}
	}

	/// The type to offer when the system has no declaration for an extension the
	/// importer still accepts. `.data` is the honest fallback: it greys out
	/// nothing, and the importer re-checks the bytes anyway.
	private static func _fallback(for extensionName: String) -> UTType {
		switch extensionName {
		case "ipa": return .ipa
		case "tipa": return .tipa
		case "zip": return .zip
		case "p12": return .p12
		case "pfx": return .pfx
		case "mobileprovision": return .mobileProvision
		case "provisionprofile": return .provisionProfile
		default: return .data
		}
	}
}