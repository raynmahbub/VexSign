//
//  FilePreviewLoader.swift
//  VexSign
//
//  What one preview screen shows, decided in one place.
//
//  Presentation, not application: it renders for two screens and speaks to the user
//  (the notice), and the application layer is deliberately free of UIKit and of the
//  localisation helper.
//
//  `FileManagerItemView` and `IPAFileViewerView` each carried their own copy of the
//  kind switch, the hex dump and the strings extractor, and neither bounded the read:
//  a `.pdf`, an image or a text file of a few hundred megabytes went through
//  `Data(contentsOf:)` on the main thread while the screen appeared. The caps live in
//  `FilePreviewLimit` and are applied here before reading, and again in the readers
//  themselves, so no other caller can reopen the hole.
//

import Foundation
import NimbleExtensions

/// The content a preview screen renders.
struct FilePreviewContent {
	var text: String?
	var plist: [String: Any]?
	/// Decoded by the view, so the application layer stays free of UIKit.
	var imageData: Data?
	var hex: String = ""
	var strings: String = ""
	/// Set when the file exists but is deliberately not read. Shown instead of the
	/// content, so "nothing here" and "too big to show" never look the same.
	var notice: String?
}

@MainActor
enum FilePreviewLoader {

	/// - Parameter includesPDFImage: `FileManagerItemView` draws a PDF as an image;
	///   the IPA explorer shows it in the binary browser instead. Passing the intent
	///   keeps the IPA screen from decoding a document it will never show.
	static func load(
		url: URL,
		kind: IPAFileKind,
		files: FileWorkspaceUseCase,
		includesPDFImage: Bool = false
	) -> FilePreviewContent {
		var content = FilePreviewContent()
		let size = files.size(at: url)

		switch kind {
		case .plist:
			guard size <= FilePreviewLimit.textBytes else {
				content.notice = tooLargeNotice(size: size, limit: FilePreviewLimit.textBytes)
				return content
			}
			// XML even when the file on disk is binary, so "Edit as Text" stays readable.
			content.text = files.plistText(at: url)
			content.plist = files.plist(at: url) as? [String: Any]

		case .text:
			guard size <= FilePreviewLimit.textBytes else {
				content.notice = tooLargeNotice(size: size, limit: FilePreviewLimit.textBytes)
				return content
			}
			content.text = files.text(at: url)

		case .image:
			(content.imageData, content.notice) = imageData(url: url, size: size, files: files)

		case .pdf where includesPDFImage:
			(content.imageData, content.notice) = imageData(url: url, size: size, files: files)

		case .executable, .binary, .database, .archive, .pdf:
			content.hex = hex(from: files.head(of: url, count: FilePreviewLimit.hexBytes))
			content.strings = strings(from: files.head(of: url, count: FilePreviewLimit.stringsBytes))

		case .directory:
			break
		}

		return content
	}

	/// Classic hex/ASCII dump of a bounded prefix.
	static func hex(from data: Data?) -> String {
		guard let data, !data.isEmpty else { return .localized("Unreadable") }

		let all = [UInt8](data)
		var lines: [String] = []

		for offset in stride(from: 0, to: all.count, by: 16) {
			let chunk = Array(all[offset..<min(offset + 16, all.count)])
			let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
			let ascii = chunk.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." }
			lines.append(String(format: "%08X  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + String(ascii))
		}

		return lines.joined(separator: "\n")
	}

	/// Printable UTF-8/ASCII runs from a bounded prefix.
	static func strings(from data: Data?) -> String {
		guard let data, !data.isEmpty else { return .localized("Unreadable") }

		var result: [String] = []
		var current: [UInt8] = []
		for byte in data {
			if byte >= 32 && byte < 127 {
				current.append(byte)
			} else if current.count >= 4 {
				result.append(String(decoding: current, as: UTF8.self))
				current.removeAll(keepingCapacity: true)
			} else {
				current.removeAll(keepingCapacity: true)
			}
		}
		if current.count >= 4 { result.append(String(decoding: current, as: UTF8.self)) }
		return result.isEmpty ? .localized("No printable strings found in the preview.") : result.joined(separator: "\n")
	}

	/// The bytes to decode, or the reason they were not read.
	private static func imageData(
		url: URL,
		size: Int64,
		files: FileWorkspaceUseCase
	) -> (Data?, String?) {
		guard size <= FilePreviewLimit.imageBytes else {
			return (nil, tooLargeNotice(size: size, limit: FilePreviewLimit.imageBytes))
		}
		return (files.data(at: url), nil)
	}

	private static func tooLargeNotice(size: Int64, limit: Int64) -> String {
		.localized(
			"This file is %@. Previews here are limited to %@, so it was not read.",
			arguments: byteText(size), byteText(limit)
		)
	}

	/// `ByteCountFormatter` lives in Foundation, so this screen does not depend on the
	/// presentation-layer formatting extension.
	private static func byteText(_ bytes: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
	}
}
