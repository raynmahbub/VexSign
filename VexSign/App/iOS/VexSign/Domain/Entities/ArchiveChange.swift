import Foundation

struct IPAChange: Identifiable, Equatable {
	enum Kind: String, Codable {
		case added
		case modified
		case removed
	}

	let id: String
	let relativePath: String
	let kind: Kind
	/// Filename inside the journal's `Backups/` folder holding the original bytes (nil for added).
	let backupName: String?
	let date: Date

}
