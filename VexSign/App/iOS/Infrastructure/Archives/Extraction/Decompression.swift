//
//  Decompression.swift
//  vexsign
//
//  Created by VexSign Contributors on 21.08.2024.
//  Copyright (c) 2026 VexSign Team
//

import Foundation
import SWCompression
import Compression
import OSLog

/// Decompresses or untars `fileURL` in place (the URL is updated to point at the result).
///
/// Compression is detected by **magic bytes**, not the file extension — `.deb` payloads are
/// routinely mislabelled (e.g. a `data.tar.lzma` that is actually XZ), which used to throw
/// `LZMAError` and silently drop the tweak. XZ is decoded via Apple's `Compression` framework
/// first (fast + robust), falling back to the pure-Swift SWCompression decoder.
func extractFile(at fileURL: inout URL) throws {
	let fileManager = FileManager.default
	let data = try Data(contentsOf: fileURL)

	// A .tar (already decompressed) → unpack into a directory.
	if fileURL.pathExtension.lowercased() == "tar" || _looksLikeTar(data) {
		let extractionDirectory = fileURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
		try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)

		let tarContainer = try TarContainer.open(container: data)
		let standardizedExtractionDir = extractionDirectory.standardizedFileURL.path
		for entry in tarContainer {
			// Security: archive entries are untrusted input.
			//  1. Reject absolute paths and any `..` component (path traversal).
			//  2. Never materialize symlinks/hardlinks/devices — a symlink that
			//     escapes the extraction directory is a classic archive attack.
			//  3. Only plain files and directories are written; anything else is
			//     skipped (and logged) rather than interpreted.
			guard _isSafeArchiveEntryName(entry.info.name) else {
				_ = SECURE_ARCHIVE_LOG.skipped(entry.info.name, reason: "unsafe path")
				continue
			}
			guard entry.info.type == .directory || entry.info.type == .regular else {
				_ = SECURE_ARCHIVE_LOG.skipped(entry.info.name, reason: "non-regular entry (link/device/fifo)")
				continue
			}

			let entryPath = extractionDirectory.appendingPathComponent(entry.info.name)
			// Backstop: the resolved destination must stay inside the
			// extraction directory even if a name slipped past the checks.
			guard entryPath.standardizedFileURL.path.hasPrefix(standardizedExtractionDir) else {
				_ = SECURE_ARCHIVE_LOG.skipped(entry.info.name, reason: "resolved outside extraction directory")
				continue
			}
			if entry.info.type == .directory {
				try fileManager.createDirectory(at: entryPath, withIntermediateDirectories: true)
			} else if entry.info.type == .regular, let entryData = entry.data {
				try fileManager.createDirectory(at: entryPath.deletingLastPathComponent(), withIntermediateDirectories: true)
				try entryData.write(to: entryPath)
			}
		}
		fileURL = extractionDirectory
		return
	}

	let decompressed: Data
	switch _detectCompression(data, extensionHint: fileURL.pathExtension.lowercased()) {
	case .xz:
		// Apple's COMPRESSION_LZMA decodes the XZ container; fall back to SWCompression.
		decompressed = try (_appleDecompress(data, algorithm: COMPRESSION_LZMA) ?? XZArchive.unarchive(archive: data))
	case .lzma:
		decompressed = try LZMA.decompress(data: data)
	case .gzip:
		decompressed = try GzipArchive.unarchive(archive: data)
	case .bzip2:
		decompressed = try BZip2.decompress(data: data)
	case .unknown:
		throw TweakHandlerError.unsupportedFileExtension(fileURL.pathExtension)
	}

	let outputURL = fileURL.deletingPathExtension()
	try decompressed.write(to: outputURL)
	fileURL = outputURL
}

// MARK: - Secure extraction helpers

/// Validates an archive entry name before anything is written to disk.
///
/// An entry is safe when it is relative, has no `..` component, no drive
/// letter (Windows-style), no backslash separator trickery and no NUL byte.
/// This is deliberately conservative: rather than resolving and re-checking a
/// suspicious path, the entry is rejected outright.
func _isSafeArchiveEntryName(_ name: String) -> Bool {
	if name.isEmpty { return false }
	if name.hasPrefix("/") { return false }             // absolute path
	if name.contains("\0") { return false }             // NUL byte
	if name.contains("\\") { return false }             // backslash separator / drive letters
	if name.hasPrefix("~") { return false }             // home-relative
	let components = name.split(separator: "/", omittingEmptySubsequences: true)
	if components.isEmpty { return false }
	for component in components {
		if component == ".." { return false }           // parent traversal
		if component == "." { continue }
	}
	return true
}

/// Central logging for skipped archive entries. Surfaces in the unified log
/// (and the Diagnostics Center) so a malicious archive is visible instead of
/// silently dropping entries.
enum SECURE_ARCHIVE_LOG {
	@discardableResult
	static func skipped(_ name: String, reason: String) -> Bool {
		Logger.security.warning("Archive entry skipped (\(reason, privacy: .public)): \(name, privacy: .public)")
		return false
	}
}

// MARK: - Format detection

private enum _CompressionFormat { case xz, lzma, gzip, bzip2, unknown }

/// Detects compression by magic bytes, falling back to the extension only when no magic matches.
private func _detectCompression(_ data: Data, extensionHint ext: String) -> _CompressionFormat {
	let m = [UInt8](data.prefix(6))
	if m.count >= 6, m[0] == 0xFD, m[1] == 0x37, m[2] == 0x7A, m[3] == 0x58, m[4] == 0x5A, m[5] == 0x00 {
		return .xz // "\xFD7zXZ\x00"
	}
	if m.count >= 2, m[0] == 0x1F, m[1] == 0x8B { return .gzip }             // gzip
	if m.count >= 3, m[0] == 0x42, m[1] == 0x5A, m[2] == 0x68 { return .bzip2 } // "BZh"

	// No recognizable magic — legacy raw `.lzma` has no fixed magic, so trust the extension.
	switch ext {
	case "xz": 		return .xz
	case "lzma": 	return .lzma
	case "gz": 		return .gzip
	case "bz2": 	return .bzip2
	default: 		return .unknown
	}
}

/// Heuristic for an uncompressed tar (the ustar magic sits at offset 257).
private func _looksLikeTar(_ data: Data) -> Bool {
	guard data.count > 262 else { return false }
	let magic = data.subdata(in: 257..<262)
	return magic == Data("ustar".utf8)
}

// MARK: - Apple Compression (streaming)

/// Streams `data` through Apple's `Compression` framework. Returns nil on any failure so the
/// caller can fall back to a different decoder.
private func _appleDecompress(_ data: Data, algorithm: compression_algorithm) -> Data? {
	guard !data.isEmpty else { return nil }
	let bufferSize = 1 << 20 // 1 MB scratch
	let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
	defer { dst.deallocate() }

	return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
		guard let srcBase = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }

		var stream = compression_stream(dst_ptr: dst, dst_size: bufferSize, src_ptr: srcBase, src_size: data.count, state: nil)
		guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
		defer { compression_stream_destroy(&stream) }

		var output = Data()
		let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
		while true {
			let status = compression_stream_process(&stream, flags)
			switch status {
			case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
				let produced = bufferSize - stream.dst_size
				if produced > 0 { output.append(dst, count: produced) }
				stream.dst_ptr = dst
				stream.dst_size = bufferSize
				if status == COMPRESSION_STATUS_END { return output }
			default:
				return nil
			}
		}
	}
}
