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
