// IPAExportNaming.swift
// Adapted from KorSign, Utilities/Handlers/ArchiveHandler.swift.
// Original file: Created by samara on 22.04.2025; KorSign contributors.
// Source revision and modifications: docs/THIRD_PARTY_ADAPTATIONS.md.
// Licensed under GNU GPL version 3; see the repository LICENSE.

import Foundation

/// Shared naming and non-overwriting storage for local and browser IPA exports.
enum IPAExportNaming {
	static func stem(name: String?, version: String?) -> String {
		let parts = [name, version].compactMap { value -> String? in
			guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
			return value
		}
		let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
		var stem = ""
		// Budget decomposed bytes too: filesystem normalization can expand characters.
		// Leave room for the collision suffix and extension; keep characters whole.
		for character in parts.joined(separator: " ") {
            // Foundation includes Unicode format characters in controlCharacters.
            // Keep ZWJ/ZWNJ so emoji sequences and joined-script names stay whole;
            // other controls (including bidi overrides) remain disallowed.
            let hasUnsafeScalar = character.unicodeScalars.contains { scalar in
                unsafe.contains(scalar) && scalar.value != 0x200D && scalar.value != 0x200C
            }
            let text = hasUnsafeScalar ? "_" : String(character)
			guard (stem + text).decomposedStringWithCanonicalMapping.utf8.count <= 180 else { break }
			stem += text
		}
		stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
		return stem.isEmpty ? "App" : stem
	}

    /// Adapted from KorSign's moveToArchive collision handling. Keep the source
    /// intact on failure; only an existing destination warrants a numbered retry.
    static func movePackage(_ source: URL, to directory: URL, name: String?, version: String?) throws -> URL {
        let manager = FileManager.default
        try Task.checkCancellation()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = stem(name: name, version: version)
        var number = 1
        while true {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let destination = directory.appendingPathComponent("\(base)\(suffix).ipa")
            do {
                try manager.moveItem(at: source, to: destination)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                number += 1
                continue
            }
            return destination
        }
    }
}
