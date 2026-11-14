import Foundation

struct IPAWorkspaceRecord: Identifiable, Hashable {
	let id: String
	let name: String
	let date: Date
	let isLibraryApp: Bool

	let url: URL
}
