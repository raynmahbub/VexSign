//
//  SwiftAR.swift
//  SwiftAR
//
//  Created by nekohaxx on 8/18/24.
//

import Foundation
import NimbleExtensions

class AR: NSObject {
	private var _data: Data
	
	init(with url: URL) throws {
		// A `.deb` is untrusted input and can be large. Mapping keeps the archive
		// out of the heap: only the pages this parser actually touches are read,
		// instead of a full-size buffer being allocated before the first bounds check.
		self._data = try Data(contentsOf: url, options: .mappedIfSafe)
		super.init()
	}
	
	func extract() async throws -> [ARFileModel] {
		guard _data.count >= 8 else {
			throw ARError.badArchive("Archive too small")
		}
		if [UInt8](_data.subdata(in: Range(0...7))) != [0x21, 0x3c, 0x61, 0x72, 0x63, 0x68, 0x3e, 0x0a] {
			throw ARError.badArchive("Invalid magic")
		}
		
		// A slice, not `subdata(in:)`: slicing a `Data` shares its storage, while `subdata`
		// copies. Copying here meant the whole `.deb` — up to the file-size cap — was read
		// into the heap before a single member had been bounds-checked, which is exactly the
		// allocation that turns a large archive into a jetsam kill on a phone. Offsets below
		// stay relative to the slice; `data.startIndex` is added when a byte is touched.
		let data = _data[8...]

		var offset = 0
		var files: [ARFileModel] = []
		var names = Set<String>()
		while offset < data.count {
			guard data.count - offset >= 60 else {
				throw ARError.badArchive("Header truncated")
			}
			let fileInfo = try _getFileInfo(data, offset)
			guard names.insert(fileInfo.name.lowercased()).inserted else {
				throw ARError.badArchive("Duplicate member name")
			}
			files.append(fileInfo)
			offset += fileInfo.size + 60
			if fileInfo.size % 2 != 0 {
				guard offset < data.count, data[data.startIndex + offset] == 0x0a else {
					throw ARError.badArchive("Missing or invalid member padding")
				}
				offset += 1
			}
		}
		return files
	}
	
	private func _getFileInfo(_ data: Data, _ offset: Int) throws -> ARFileModel {
		guard offset + 60 <= data.count else {
			throw ARError.badArchive("Header truncated")
		}

		// `data` is a slice of the mapped archive; every absolute index adds its start.
		let base = data.startIndex

		guard data[base + offset + 58] == 0x60, data[base + offset + 59] == 0x0a else {
			throw ARError.badArchive("Invalid member header terminator")
		}

		guard let sizeStr = String(data: data[(base + offset + 48)..<(base + offset + 58)], encoding: .ascii),
		      let size = Int(_removePadding(sizeStr)), size >= 0 else {
			throw ARError.badArchive("Invalid size")
		}

		guard size <= data.count - (offset + 60) else {
			throw ARError.badArchive("File data truncated")
		}
		
		let rawName = String(data: data[(base + offset)..<(base + offset + 16)], encoding: .ascii) ?? ""
		var name = _removePadding(rawName)
		// Some ar writers terminate a short filename with a slash. The deb
		// consumers write each member directly into a staging directory, so only
		// a single ordinary filename is allowed after removing that terminator.
		if name.hasSuffix("/") { name.removeLast() }
		guard !name.isEmpty, name != ".", name != "..",
			!name.contains("/"), !name.contains("\\"),
			name.rangeOfCharacter(from: .controlCharacters) == nil else {
			throw ARError.badArchive("Invalid member name")
		}

		let modDateStr = String(data: data[(base + offset + 16)..<(base + offset + 28)], encoding: .ascii) ?? "0"
		let modTimestamp = Double(_removePadding(modDateStr)) ?? 0
		let ownerStr = String(data: data[(base + offset + 28)..<(base + offset + 34)], encoding: .ascii) ?? "0"
		let ownerId = Int(_removePadding(ownerStr)) ?? 0
		let groupStr = String(data: data[(base + offset + 34)..<(base + offset + 40)], encoding: .ascii) ?? "0"
		let groupId = Int(_removePadding(groupStr)) ?? 0
		let modeStr = String(data: data[(base + offset + 40)..<(base + offset + 48)], encoding: .ascii) ?? "0"
		let mode = Int(_removePadding(modeStr)) ?? 0
		
		return ARFileModel(
			name: name,
			modificationDate: Date(timeIntervalSince1970: modTimestamp),
			ownerId: ownerId,
			groupId: groupId,
			mode: mode,
			size: size,
			// A slice, so reading a member never duplicates it: the payload is copied once,
			// by whoever writes it to disk, instead of once per member into the heap here.
			content: data[(base + offset + 60)..<(base + offset + 60 + size)]
		)
	}
	
	private func _removePadding(_ paddedString: String) -> String {
		paddedString.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

/// A `.deb` whose `ar` envelope cannot be read. Carries the parser's own reason, because
/// "the archive is bad" is not something a user can act on; the tweak pipeline wraps this in
/// `TweakInjectionFailure`, which shows this sentence.
enum ARError: LocalizedError, Equatable {
	case badArchive(String)

	var errorDescription: String? {
		switch self {
		case .badArchive(let reason):
			let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
			return detail.isEmpty
				? .localized("This Debian package's archive could not be read. It may be damaged or not a .deb file.")
				: .localized("This Debian package's archive could not be read: %@", arguments: detail)
		}
	}
}
