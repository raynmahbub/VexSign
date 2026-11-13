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
	static var vexBackup: UTType {
		.init(filenameExtension: "vexbackup", conformingTo: .data) ?? .data
	}
}