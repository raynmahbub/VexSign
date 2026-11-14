import Foundation

struct TweakCandidate: Identifiable, Equatable, Sendable {
	let id = UUID()
	/// On-disk location (inside a temp work dir for IPA scans, or inside the app for library scans).
	let url: URL
	/// File/bundle name, e.g. `Reveal.dylib` or `Orion.framework`.
	let name: String
	let type: TweakFileType
	let size: Int64
	/// Path relative to the scanned `.app`, for display/disambiguation.
	let relativePath: String
	/// Containing folder relative to the app/archive root ("" means the root).
	let folder: String

	static func == (lhs: TweakCandidate, rhs: TweakCandidate) -> Bool {
		lhs.id == rhs.id
	}
}
