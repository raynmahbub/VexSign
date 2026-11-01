//
//  MachOEntitlements.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation

enum MachOEntitlements {
	private static let codeSignatureCommand: UInt32 = 0x1d
	private static let embeddedSignatureMagic: UInt32 = 0xfade0cc0
	private static let entitlementsMagic: UInt32 = 0xfade7171
	private static let entitlementsSlot: UInt32 = 0x5

	static func keychainAccessGroups(forExecutableAt url: URL) -> [String] {
		read(forExecutableAt: url)?["keychain-access-groups"] as? [String] ?? []
	}

	static func read(forExecutableAt url: URL) -> [String: Any]? {
		guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
		guard let offset = codeSignatureOffset(in: data) else { return nil }
		return entitlements(in: data, at: offset)
	}

	/// True when the binary carries an `LC_CODE_SIGNATURE` load command — the
	/// cheapest on-device proof that it was signed at all. installd still decides
	/// whether the signature is acceptable; this only tells signed from unsigned.
	static func hasCodeSignature(forExecutableAt url: URL) -> Bool {
		guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
		return codeSignatureOffset(in: data) != nil
	}

	/// Absolute offset of the code signature superblob, or nil when the binary is
	/// unsigned or not a readable 64-bit Mach-O.
	///
	/// Shared with `BundleSignature`, which reads the CMS blob out of the same
	/// superblob: one walk of the load commands, one place to fix if Apple changes the layout.
	static func codeSignatureOffset(forExecutableAt url: URL) -> Int? {
		guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
		return codeSignatureOffset(in: data)
	}

	private static func codeSignatureOffset(in data: Data) -> Int? {
		let slice = MachOReader.sliceOffset(in: data)

		// iOS binaries are 64-bit
		let bigEndian: Bool
		switch MachOReader.u32(data, at: slice, bigEndian: false) {
		case MachOReader.machO64: bigEndian = false
		case MachOReader.machO64Swapped: bigEndian = true
		default: return nil
		}

		guard let ncmds = MachOReader.u32(data, at: slice + 16, bigEndian: bigEndian) else { return nil }
		var cmd = slice + MachOReader.machHeader64Size

		for _ in 0..<ncmds {
			guard
				let cmdId = MachOReader.u32(data, at: cmd, bigEndian: bigEndian),
				let cmdSize = MachOReader.u32(data, at: cmd + 4, bigEndian: bigEndian),
				cmdSize >= 8
			else { return nil }

			if cmdId == codeSignatureCommand, let off = MachOReader.u32(data, at: cmd + 8, bigEndian: bigEndian) {
				return slice + Int(off)
			}

			cmd += Int(cmdSize)
		}

		return nil
	}

	// Code signature blobs are always big-endian, regardless of the host or Mach-O slice.
	private static func entitlements(in data: Data, at codeSig: Int) -> [String: Any]? {
		guard
			MachOReader.u32(data, at: codeSig, bigEndian: true) == embeddedSignatureMagic,
			let count = MachOReader.u32(data, at: codeSig + 8, bigEndian: true)
		else { return nil }

		for i in 0..<Int(count) {
			let index = codeSig + 12 + i * 8
			guard
				let type = MachOReader.u32(data, at: index, bigEndian: true),
				let blobOff = MachOReader.u32(data, at: index + 4, bigEndian: true)
			else { return nil }

			guard type == entitlementsSlot else { continue }

			let blob = codeSig + Int(blobOff)
			guard
				MachOReader.u32(data, at: blob, bigEndian: true) == entitlementsMagic,
				let length = MachOReader.u32(data, at: blob + 4, bigEndian: true),
				length > 8
			else { return nil }

			let start = blob + 8
			let end = blob + Int(length)
			guard start <= end, end <= data.count else { return nil }

			let plist = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
			return (try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)) as? [String: Any]
		}

		return nil
	}
}
