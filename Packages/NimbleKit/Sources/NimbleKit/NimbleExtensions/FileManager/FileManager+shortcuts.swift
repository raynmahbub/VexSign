//
//  FileManager+bundle.swift
//  VexSign
//
//  Created by VexSign Contributors on 16.04.2025.
//

import Foundation.NSFileManager

extension FileManager {
	public func getPath(in directory: URL, for pathExtension: String) -> URL? {
		guard let contents = try? contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
			return nil
		}
		
        // Extensions in imported archives and Files-provider exports are not
        // guaranteed to preserve case. Bundle/profile lookups must agree with
        // the case-insensitive package semantics used by signing inventory.
		return contents.first(where: { $0.pathExtension.caseInsensitiveCompare(pathExtension) == .orderedSame })
	}
	
	public func isFileFromFileProvider(at url: URL) -> Bool {
		if let resourceValues = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .fileResourceIdentifierKey]),
		   resourceValues.isUbiquitousItem == true {
			return true
		}
		
		let path = url.path
		if path.contains("/Library/CloudStorage/") || path.contains("/File Provider VexSign/Storage/") {
			return true
		}
		
		return false
	}
	
	public func removeFileIfNeeded(at url: URL) throws {
		if self.fileExists(atPath: url.path) {
			try self.removeItem(at: url)
		}
	}
	
	public func moveFileIfNeeded(from sourceURL: URL, to destinationURL: URL) throws {
		if !self.fileExists(atPath: destinationURL.path) {
			try self.moveItem(at: sourceURL, to: destinationURL)
		}
	}
	
	public func createDirectoryIfNeeded(at url: URL) throws {
		if !self.fileExists(atPath: url.path) {
			try self.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
		}
	}
	
	static public func forceWrite(content: String, to filename: String) throws {
		let path = URL.documentsDirectory.appendingPathComponent(filename)
		try content.write(to: path, atomically: true, encoding: .utf8)
	}
	
	/// Decodes a base64 payload carried by a deep link and stages it in a unique
	/// temporary file. External certificate/profile callbacks use both standard
	/// base64 and base64url, and are often sent without padding or with line
	/// breaks. Normalise those forms, bound the decoded size so a hostile link
	/// cannot allocate unbounded memory, and keep the staged write best-effort:
	/// the caller validates the resulting file before importing anything.
	public func decodeAndWrite(base64: String, pathComponent: String, maxBytes: Int = 16 << 20) -> URL? {
		guard maxBytes > 0 else { return nil }

		// Reject on the *encoded* length before touching the payload. Whitespace
		// filtering and the two base64url substitutions each copy the whole string,
		// so checking `data.count` afterwards meant a hostile megabyte link allocated
		// several times `maxBytes` before the cap was ever consulted. Base64 expands by
		// 4/3; the slack covers whitespace and padding a well-formed link may carry.
		let encodedLimit = ((maxBytes + 2) / 3) * 4
		let slack = encodedLimit / 16 + 1024
		guard base64.utf8.count <= encodedLimit + slack else { return nil }

		var cleaned = base64
		if cleaned.contains(where: { $0.isWhitespace }) {
			cleaned = cleaned.filter { !$0.isWhitespace }
		}
		if cleaned.contains("-") {
			cleaned = cleaned.replacingOccurrences(of: "-", with: "+")
		}
		if cleaned.contains("_") {
			cleaned = cleaned.replacingOccurrences(of: "_", with: "/")
		}
		guard !cleaned.isEmpty else { return nil }
		let remainder = cleaned.count % 4
		if remainder != 0 {
			cleaned += String(repeating: "=", count: 4 - remainder)
		}
		guard
			let data = Data(base64Encoded: cleaned),
			!data.isEmpty,
			data.count <= maxBytes
		else { return nil }
		let dir = self.temporaryDirectory.appendingPathComponent(UUID().uuidString + pathComponent)
		try? data.write(to: dir) // try? ok: best-effort write to temp directory; caller validates file existence
		return dir
	}
	
	// VexSignTweak
	public func moveAndStore(_ url: URL, with prepend: String, completion: @escaping (URL) -> Void) {
		let destination = _getDestination(url, with: prepend)
		
		try? createDirectoryIfNeeded(at: destination.temp) // try? ok: directory may already exist
		
		try? self.copyItem(at: url, to: destination.dest) // try? ok: best-effort copy; completion receives destination regardless
		completion(destination.dest)
	}
	
	public func deleteStored(_ url: URL, completion: @escaping (URL) -> Void) {
		try? FileManager.default.removeItem(at: url) // try? ok: best-effort deletion
		completion(url)
	}
	
	// VexSignTweak
	private func _getDestination(_ url: URL, with prepend: String) -> (temp: URL, dest: URL) {
		let tempDir = self.temporaryDirectory.appendingPathComponent("\(prepend)_\(UUID().uuidString)", isDirectory: true)
		let destinationUrl = tempDir.appendingPathComponent(url.lastPathComponent)
		return (tempDir, destinationUrl)
	}
}
