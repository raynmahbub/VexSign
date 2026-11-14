import Foundation

enum BackupPolicy { static let minimumPasswordLength = 8 }
enum BackupImportProtection: Sendable { case legacyPlaintext, password, deviceOnly }
struct BackupAvailability: Sendable {
    let components: BackupComponents
    let counts: [BackupComponents: Int]
}
/// An opaque preview, never a decrypted manifest, certificate password or root.
struct BackupArchiveSnapshot: Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let appVersion: String
    let schemaVersion: Int
    let contents: BackupComponents
    let counts: [BackupComponents: Int]
    let integrity: BackupIntegrity
}

struct BackupComponents: OptionSet, Hashable, Codable, Sendable {
	let rawValue: Int

	static let certificates = BackupComponents(rawValue: 1 << 0)
	static let sources = BackupComponents(rawValue: 1 << 1)
	static let settings = BackupComponents(rawValue: 1 << 2)
	static let tweaks = BackupComponents(rawValue: 1 << 3)
    static let library = BackupComponents(rawValue: 1 << 4)

	static let ordered: [BackupComponents] = [.certificates, .sources, .settings, .tweaks, .library]

	init(rawValue: Int) { self.rawValue = rawValue }

	init(from decoder: Decoder) throws {
		rawValue = try decoder.singleValueContainer().decode(Int.self)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

}

struct BackupIntegrity: Sendable {
	/// SHA-256 of the decrypted archive, so two backups of the same content can be
	/// told apart from two that merely look alike.
	let packSHA256: String
	let certificateEntries: Int
	let certificateDirectories: Int

	var isComplete: Bool { certificateDirectories == certificateEntries }

}

struct BackupRestoreTally: Sendable {
	private(set) var added = 0
	private(set) var skipped = 0

	mutating func recordAttempt(error: Error?) {
		if error == nil { added += 1 } else { skipped += 1 }
	}

	mutating func recordSkipped() {
		skipped += 1
	}
}

struct BackupRestoreSummary: Sendable {
	private(set) var restored: BackupComponents = []
	private var _added: [BackupComponents: Int] = [:]
	private var _skipped: [BackupComponents: Int] = [:]
	/// What a post-restore read found actually in place, per component.
	private var _verified: [BackupComponents: Int] = [:]

	mutating func record(_ component: BackupComponents, added: Int, skipped: Int) {
		restored.insert(component)
		_added[component] = added
		_skipped[component] = max(0, skipped)
	}

	mutating func recordVerification(_ component: BackupComponents, verified: Int) {
		_verified[component] = max(0, verified)
	}

	/// Restored items the post-restore read could not find.
	///
	/// A restore reports what it attempted; this is the part that was checked afterwards. The
	/// two disagree only when a write silently did not stick, and that is exactly the case a
	/// success message must never hide.
	var unverified: Int {
		// A loop, not `restored.reduce`: `restored` is an OptionSet and has no `reduce` at
		// all. The original one-liner was invalid rather than merely slow, and the compiler
		// reported a type-check timeout instead of the missing member.
		var total: Int = 0
		// `restored` is an OptionSet, not a collection, so the members come from `ordered`.
		for component in BackupComponents.ordered where restored.contains(component) {
			let added: Int = _added[component] ?? 0
			let verified: Int = _verified[component] ?? 0
			total += max(0, added - verified)
		}
		return total
	}

	/// One summary line, kept out of the loop body: the branch over a variadic
	/// `localized(_:arguments:)` in a single expression was slow enough for the type
	/// checker to give up on the whole property.

    var hasVerification: Bool { !_verified.isEmpty }
    func counts(for component: BackupComponents) -> (added: Int, skipped: Int) {
        (_added[component] ?? 0, _skipped[component] ?? 0)
    }
}
