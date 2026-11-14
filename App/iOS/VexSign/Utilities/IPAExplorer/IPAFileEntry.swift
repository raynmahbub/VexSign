//
//  IPAFileEntry.swift
//  VexSign
//
//  One row in the IPA Explorer: a file or folder inside an IPA's `Payload/…app` tree, plus the
//  type detection that decides how it opens (plist editor, text editor, image viewer, info view).
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import NimbleExtensions

// MARK: - Kind
enum IPAFileKind: String {
	case directory
	case plist
	case text
	case image
	case pdf
	case executable
	case archive
	case database
	case binary

	var title: String {
		switch self {
		case .directory:	.localized("Folder")
		case .plist:		.localized("Property List")
		case .text:			.localized("Text")
		case .image:		.localized("Image")
		case .pdf:			.localized("PDF")
		case .executable:	.localized("Executable")
		case .archive:		.localized("Archive")
		case .database:		.localized("Database")
		case .binary:		.localized("Binary")
		}
	}

	var systemImage: String {
		switch self {
		case .directory:	"folder"
		case .plist:		"list.bullet.rectangle"
		case .text:			"doc.text"
		case .image:		"photo"
		case .pdf:			"doc.richtext"
		case .executable:	"gearshape.2"
		case .archive:		"archivebox"
		case .database:		"cylinder.split.1x2"
		case .binary:		"doc"
		}
	}

	var tint: Color {
		switch self {
		case .directory:	.accentColor
		case .plist:		.purple
		case .text:			.blue
		case .image:		.green
		case .pdf:			.red
		case .executable:	.orange
		case .archive:		.brown
		case .database:		.teal
		case .binary:		.gray
		}
	}

	/// Kinds the user can edit in place with the built-in editor.
	var isEditable: Bool {
		switch self {
		case .plist, .text: true
		default: false
		}
	}

	var isPreviewable: Bool {
		switch self {
		case .image, .pdf, .text, .plist, .executable, .binary, .database, .archive: true
		case .directory: false
		}
	}
}

// MARK: - Entry
struct IPAFileEntry: Identifiable, Hashable, SortableItem {
	let url: URL
	let name: String
	let isDirectory: Bool
	let size: Int64
	let date: Date
	let kind: IPAFileKind
	let childCount: Int

	var id: String { url.path }
	var sortName: String { name }
	var sortDate: Date { date }
	var sortSize: Int64 { size }

	var isHiddenByDefault: Bool { name.hasPrefix(".") }
}

// MARK: - Bundle summary
/// Everything the explorer shows above the file list for an `.app` bundle.
struct IPABundleSummary {
	let name: String
	let identifier: String
	let version: String
	let build: String?
	let minimumOS: String?
	let executable: String?
	let icon: UIImage?
	let fileCount: Int
	let size: Int64
	/// `Info.plist` is missing or unreadable — the bundle is damaged or not an app.
	let isBroken: Bool

	static func read(at appURL: URL) -> IPABundleSummary {
		let bundle = Bundle(url: appURL)
		let info = bundle?.infoDictionary

		return IPABundleSummary(
			name: bundle?.name ?? appURL.deletingPathExtension().lastPathComponent,
			identifier: bundle?.bundleIdentifier ?? (info?["CFBundleIdentifier"] as? String) ?? "—",
			version: bundle?.version ?? "—",
			build: info?["CFBundleVersion"] as? String,
			minimumOS: info?["MinimumOSVersion"] as? String,
			executable: bundle?.exec.isEmpty == false ? bundle?.exec : nil,
			icon: icon(in: appURL, bundle: bundle),
			fileCount: fileCount(in: appURL),
			size: FileManager.default.allocatedSize(at: appURL),
			isBroken: bundle?.bundleIdentifier == nil
		)
	}

	/// Largest matching PNG for `CFBundleIcons` — the closest thing to a retina app icon.
	private static func icon(in appURL: URL, bundle: Bundle?) -> UIImage? {
		guard let base = bundle?.iconFileName, !base.isEmpty else { return nil }

		let files = (try? FileManager.default.contentsOfDirectory(at: appURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? [] // try? ok: best-effort bundle listing
		let matches = files
			.filter { $0.lastPathComponent.lowercased().hasPrefix(base.lowercased()) && $0.pathExtension.lowercased() == "png" }
			.sorted { ($0.lastPathComponent.count) > ($1.lastPathComponent.count) }

		guard let url = matches.first, let data = try? Data(contentsOf: url) else { return nil } // try? ok: optional icon read; no icon when unreadable
		return UIImage(data: data)
	}

	private static func fileCount(in appURL: URL) -> Int {
		guard let enumerator = FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
		var count = 0
		for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false { // try? ok: best-effort file probe during enumeration
			count += 1
		}
		return count
	}
}

// MARK: - Loader
enum IPAFileLoader {
	private static let _fileManager = FileManager.default

	private static let _textExtensions: Set<String> = [
		"txt", "json", "xml", "html", "htm", "css", "js", "strings", "stringsdict",
		"md", "markdown", "csv", "yml", "yaml", "sh", "entitlements", "log", "conf",
		"config", "ini", "swift", "m", "mm", "h", "c", "cpp", "pbxproj", "xcconfig", "rtf"
	]

	private static let _imageExtensions: Set<String> = [
		"png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "icns", "ico"
	]

	private static let _archiveExtensions: Set<String> = [
		"zip", "ipa", "tipa", "deb", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "car"
	]

	private static let _databaseExtensions: Set<String> = ["sqlite", "sqlite3", "db", "db-wal", "db-shm"]

	/// Sorted, folders first.
	///
	/// `measuringDirectorySize` walks a whole subtree to size it. The IPA Explorer wants that
	/// (an app bundle is one folder), a Documents browser does not — listing `/Documents`
	/// would re-walk every signed app just to show a number nothing renders.
	static func children(
		of directory: URL,
		includesHidden: Bool = false,
		measuringDirectorySize: Bool = true
	) -> [IPAFileEntry] {
		let urls = (try? _fileManager.contentsOfDirectory( // try? ok: best-effort directory listing
			at: directory,
			includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
			options: []
		)) ?? []

		return urls
			.filter { includesHidden || !$0.lastPathComponent.hasPrefix(".") }
			.map { entry(at: $0, measuringDirectorySize: measuringDirectorySize) }
			.sorted {
				if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
				return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
			}
	}

	static func entry(at url: URL, measuringDirectorySize: Bool = true) -> IPAFileEntry {
		let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]) // try? ok: best-effort attribute probe; unknown attributes render as placeholders
		let isDirectory = values?.isDirectory == true

		return IPAFileEntry(
			url: url,
			name: url.lastPathComponent,
			isDirectory: isDirectory,
			size: isDirectory
				? (measuringDirectorySize ? _fileManager.allocatedSize(at: url) : 0)
				: Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0),
			date: values?.contentModificationDate ?? .distantPast,
			kind: kind(of: url, isDirectory: isDirectory),
			childCount: isDirectory
				? children(of: url, includesHidden: true, measuringDirectorySize: false).count
				: 0
		)
	}

	/// Extension first (cheap), then a peek at the header for the files that don't have one —
	/// the main app binary, `Info.plist` variants, images without extensions, Mach-O dylibs.
	static func kind(of url: URL, isDirectory: Bool) -> IPAFileKind {
		if isDirectory { return .directory }

		let name = url.lastPathComponent.lowercased()
		let ext = url.pathExtension.lowercased()

		if ext == "plist" { return .plist }
		if _textExtensions.contains(ext) { return .text }
		if _imageExtensions.contains(ext) { return .image }
		if ext == "pdf" { return .pdf }
		if _archiveExtensions.contains(ext) { return .archive }
		if _databaseExtensions.contains(ext) { return .database }

		if name == "pkginfo" || name == "pkgversion" { return .text }

		if let head = head(of: url, count: 8) {
			if isMachO(head) { return .executable }
			if isPNG(head) || isJPEG(head) || isGIF(head) { return .image }
			if isSQLite(head) { return .database }
			if isZip(head) { return .archive }
		}

		// Unlabeled small files are almost always text (`.strings` variants, licence files).
		if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size < 1_048_576, isText(url) { // try? ok: best-effort size probe gating the text preview
			return .text
		}

		return .binary
	}

	// MARK: Sniffing

	static func head(of url: URL, count: Int) -> Data? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil } // try? ok: optional preview read; nil when the file cannot be opened
		defer { try? handle.close() } // try? ok: preserve the primary read result
		guard let data = try? handle.read(upToCount: count) else { return nil } // try? ok: optional preview read; nil when the file cannot be read
		return data
	}

	private static func isMachO(_ data: Data) -> Bool {
		guard let magic = bigEndianUInt32(data) else { return false }
		// 32/64-bit thin + fat, both endiannesses.
		return [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf].contains(magic)
	}

	/// First four bytes read big-endian, so the magic numbers can be compared literally on any
	/// endianness without touching unsafe pointers.
	private static func bigEndianUInt32(_ data: Data) -> UInt32? {
		let bytes = [UInt8](data.prefix(4))
		guard bytes.count == 4 else { return nil }
		return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
	}

	private static func isPNG(_ data: Data) -> Bool {
		data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
	}

	private static func isJPEG(_ data: Data) -> Bool {
		data.prefix(2) == Data([0xFF, 0xD8])
	}

	private static func isGIF(_ data: Data) -> Bool {
		data.prefix(3) == Data("GIF".utf8)
	}

	private static func isSQLite(_ data: Data) -> Bool {
		data.prefix(6) == Data("SQLite".utf8)
	}

	private static func isZip(_ data: Data) -> Bool {
		data.prefix(2) == Data([0x50, 0x4B])
	}

	static func isText(_ url: URL) -> Bool {
		guard let head = head(of: url, count: 4096), !head.isEmpty else { return false }
		if head.contains(0) { return false }
		return String(data: head, encoding: .utf8) != nil
	}

	// MARK: Reading

	/// Raw text of a file, when it decodes.
	static func text(at url: URL) -> String? {
		guard let data = try? Data(contentsOf: url) else { return nil } // try? ok: optional file read; nil when unreadable
		if let text = String(data: data, encoding: .utf8) { return text }
		if let text = String(data: data, encoding: .isoLatin1) { return text }
		return nil
	}

	/// XML text for a property list, binary or not. `nil` when it can't be parsed.
	static func plistText(at url: URL) -> String? {
		guard
			let data = try? Data(contentsOf: url), // try? ok: optional plist read; nil when unreadable
			let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil), // try? ok: optional plist parse; nil when not a plist
			let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) // try? ok: optional plist-to-XML conversion for display
		else {
			return nil
		}
		return String(data: xml, encoding: .utf8)
	}

	/// Parsed property list, when it is one.
	static func plist(at url: URL) -> Any? {
		guard
			let data = try? Data(contentsOf: url), // try? ok: optional plist read; nil when unreadable
			let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) // try? ok: optional plist parse; nil when not a plist
		else {
			return nil
		}
		return object
	}

	/// Writes a property list (XML) and returns whether it parsed first.
	@discardableResult
	static func write(plist object: Any, to url: URL) -> Bool {
		guard let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) else { // try? ok: serialisation failure is surfaced as a false return
			return false
		}
		return (try? data.write(to: url, options: .atomic)) != nil // try? ok: write failure is surfaced as a false return
	}

	/// Formatted byte count, shared by every row and header in the explorer.
	static func sizeText(_ bytes: Int64) -> String {
		bytes.formattedFileSize
	}
}
