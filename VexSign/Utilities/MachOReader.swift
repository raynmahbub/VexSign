//
//  MachOReader.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation

/// Bounds checked reads over third party Mach-O binaries: malformed input returns nil or empty.
enum MachOReader {
	static let machO64: UInt32 = 0xfeedfacf
	static let machO64Swapped: UInt32 = 0xcffaedfe
	static let fat: UInt32 = 0xcafebabe
	static let fat64: UInt32 = 0xcafebabf
	static let cpuTypeArm64: UInt32 = 0x0100000c
	static let machHeader64Size = 32

	private static let loadDylib: UInt32 = 0x0c
	private static let loadWeakDylib: UInt32 = 0x80000018

	/// `LC_LOAD_DYLIB` and `LC_LOAD_WEAK_DYLIB` paths of the arm64 slice, deduplicated.
	static func dylibs(forExecutableAt url: URL) -> [String] {
		guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }

		return dylibs(in: data)
	}

	static func dylibs(in data: Data) -> [String] {
		let slice = sliceOffset(in: data)

		let bigEndian: Bool
		switch u32(data, at: slice, bigEndian: false) {
		case machO64: bigEndian = false
		case machO64Swapped: bigEndian = true
		default: return []
		}

		guard let ncmds = u32(data, at: slice + 16, bigEndian: bigEndian), ncmds <= 65_536,
			  let commandBytes = u32(data, at: slice + 20, bigEndian: bigEndian),
			  commandBytes <= 16 * 1024 * 1024,
			  slice <= data.count - machHeader64Size,
			  Int(commandBytes) <= data.count - slice - machHeader64Size,
			  Int(ncmds) <= Int(commandBytes) / 8 else { return [] }
		let commandEnd = slice + machHeader64Size + Int(commandBytes)
		var cmd = slice + machHeader64Size
		var seen = Set<String>()
		var loads: [String] = []

		for _ in 0..<ncmds {
			guard
				cmd <= commandEnd - 8,
				let cmdId = u32(data, at: cmd, bigEndian: bigEndian),
				let cmdSize = u32(data, at: cmd + 4, bigEndian: bigEndian),
				cmdSize >= 8,
				cmd + Int(cmdSize) <= commandEnd
			else { break }

			if
				cmdId == loadDylib || cmdId == loadWeakDylib,
				cmdSize >= 24,
				let nameOffset = u32(data, at: cmd + 8, bigEndian: bigEndian),
				nameOffset >= 24,
				let name = cString(in: data, from: cmd + Int(nameOffset), limit: cmd + Int(cmdSize)),
				seen.insert(name).inserted
			{
				loads.append(name)
			}

			cmd += Int(cmdSize)
		}

		return loads
	}

	private static func cString(in data: Data, from start: Int, limit: Int) -> String? {
		guard start >= 0, start < limit, limit <= data.count else { return nil }
		let base = data.startIndex
		var end = start
		while end < limit, data[base + end] != 0 { end += 1 }
		guard end > start, end < limit else { return nil }
		return String(decoding: data[(base + start)..<(base + end)], as: UTF8.self)
	}

	// Fat headers are always big-endian
	static func sliceOffset(in data: Data) -> Int {
		let entrySize: Int
		switch u32(data, at: 0, bigEndian: true) {
		case fat: entrySize = 20
		case fat64: entrySize = 32
		default: return 0
		}

		guard let nfat = u32(data, at: 4, bigEndian: true),
			  Int(nfat) <= max(0, data.count - 8) / entrySize else { return 0 }
		var fallback = 0

		for i in 0..<Int(nfat) {
			let entry = 8 + i * entrySize
			let offsetField = entry + 8
			guard
				let cpuType = u32(data, at: entry, bigEndian: true),
				let off = u32(data, at: offsetField, bigEndian: true)
			else { break }

			var offset = UInt64(off)
			if entrySize == 32 {
				guard let low = u32(data, at: offsetField + 4, bigEndian: true) else { return 0 }
				offset = (offset << 32) | UInt64(low)
			}
			guard offset <= UInt64(data.count), UInt64(data.count) - offset >= UInt64(machHeader64Size) else { continue }
			if cpuType == cpuTypeArm64 { return Int(offset) }
			if fallback == 0 { fallback = Int(offset) }
		}

		return fallback
	}

	static func u32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32? {
		guard offset >= 0, offset <= data.count, data.count - offset >= 4 else { return nil }
		let base = data.startIndex + offset
		let b0 = UInt32(data[base]), b1 = UInt32(data[base + 1])
		let b2 = UInt32(data[base + 2]), b3 = UInt32(data[base + 3])
		return bigEndian
			? (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
			: (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
	}
}
