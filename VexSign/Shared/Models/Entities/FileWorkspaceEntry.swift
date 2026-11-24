import Foundation

enum IPAFileKind: String, Sendable {
	case directory
	case plist
	case text
	case image
	case pdf
	case executable
	case archive
	case database
	case binary

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

/// How much of a file a preview may read.
///
/// Both preview screens read whole files into memory on the main thread while they
/// appeared, so a `.pdf`, an image or a log file of a few hundred megabytes was a
/// freeze (and a memory spike) rather than a screen. The numbers live here so the
/// reader, the preview loader and the notice they show cannot disagree.
enum FilePreviewLimit {
	/// Editable text and property lists. Generous for a `.strings` file or a config,
	/// far below anything that would make an in-place editor unusable.
	static let textBytes: Int64 = 8 * 1024 * 1024
	/// Bitmap and PDF previews, decoded for display.
	static let imageBytes: Int64 = 12 * 1024 * 1024
	/// The hex dump and the strings extractor already read through `head(of:count:)`.
	static let hexBytes = 1024
	static let stringsBytes = 64 * 1024
}

// MARK: - Entry
struct IPAFileEntry: Identifiable, Hashable, SortableItem, Sendable {
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
	let iconData: Data?
	let fileCount: Int
	let size: Int64
	/// `Info.plist` is missing or unreadable — the bundle is damaged or not an app.
	let isBroken: Bool

}
