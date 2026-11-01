//
//  SourceProvenance.swift
//  VexSign
//
//  a repository can prove who it is, and VexSign says so instead of asking the user to
//  toggle a "trusted" badge by hand. The existing badge stays (it is the user's own opinion); this
//  is evidence.
//
//  The format is deliberately boring, because a signature scheme nobody else can implement is a
//  lock with no key:
//
//      {
//        "name": "Example",
//        "apps": [ … ],
//        "vexsign": {
//          "algorithm": "ed25519",
//          "publicKey": "<base64, 32 raw bytes>",
//          "signature": "<base64, 64 bytes>",
//          "publisher": "Example"          // optional, display only
//        }
//      }
//
//  The signature covers the *canonical* form of the document: the `vexsign` member removed, the
//  rest re-serialised with sorted keys and no whitespace. Both sides of the scheme use that rule,
//  which is why it is written down here and in docs/SOURCE_SIGNING.md.
//
//  Policy, and why: unsigned is the normal case for every AltStore repository in existence, so an
//  unsigned feed is accepted and labelled unsigned. A feed that *claims* a signature and does not
//  verify is rejected — that is either a broken publisher or an attacker, and neither deserves a
//  refresh.
//

import Foundation
import CryptoKit
import NimbleExtensions

// MARK: - Model

struct SourceSignature: Equatable, Sendable {
	var algorithm: String
	var publicKey: String
	var signature: String
	var publisher: String?
}

enum SourceProvenance: Equatable, Sendable {
	/// No `vexsign` member: the ordinary case.
	case unsigned
	/// A signature was present and verified.
	case verified(publisher: String?)
	/// A signature was present and did not verify against the document.
	case claimedButInvalid(reason: String)

	/// Should a refresh accept this document?
	var isAcceptable: Bool {
		switch self {
		case .unsigned, .verified:
			return true
		case .claimedButInvalid:
			return false
		}
	}

	var badgeTitle: String? {
		switch self {
		case .unsigned:
			return nil
		case .verified(let publisher):
			return publisher.map { String.localized("Signed by %@", arguments: $0) } ?? .localized("Signed")
		case .claimedButInvalid:
			return .localized("Bad signature")
		}
	}
}

// MARK: - Verification

enum SourceProvenanceVerifier {
	static let fieldName = "vexsign"

	/// The bytes the signature is computed over. `nil` when the document is not a JSON object, which
	/// is the same situation as "nothing was signed".
	static func canonicalBytes(_ document: Data) -> Data? {
		guard
			let object = try? JSONSerialization.jsonObject(with: document), // try? ok: not-JSON input has nothing to inspect
			var root = object as? [String: Any]
		else {
			return nil
		}

		root.removeValue(forKey: fieldName)
		return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) // try? ok: not-JSON input has nothing to inspect
	}

	/// Reads the `vexsign` member, if there is one.
	static func signature(in document: Data) -> SourceSignature? {
		guard
			let object = try? JSONSerialization.jsonObject(with: document), // try? ok: not-JSON input has nothing to inspect
			let root = object as? [String: Any],
			let raw = root[fieldName] as? [String: Any],
			let algorithm = raw["algorithm"] as? String,
			let publicKey = raw["publicKey"] as? String,
			let signature = raw["signature"] as? String
		else {
			return nil
		}

		return SourceSignature(
			algorithm: algorithm,
			publicKey: publicKey,
			signature: signature,
			publisher: raw["publisher"] as? String
		)
	}

	/// Does the document even mention the member? A byte search is enough, and it keeps the common
	/// case — every unsigned repository in existence — from parsing a multi-megabyte feed just to
	/// find out there is nothing to verify. That matters because this runs on every refresh, on the
	/// thread moved the decode to.
	static func claimsSignature(_ document: Data) -> Bool {
		document.range(of: Data("\"\(fieldName)\"".utf8)) != nil
	}

	static func evaluate(_ document: Data) -> SourceProvenance {
		guard claimsSignature(document), let claimed = signature(in: document) else {
			return .unsigned
		}
		return verify(claimed, in: document)
	}

	static func verify(_ claimed: SourceSignature, in document: Data) -> SourceProvenance {
		guard claimed.algorithm.lowercased() == "ed25519" else {
			return .claimedButInvalid(reason: .localized("This source is signed with an algorithm VexSign does not support (%@).", arguments: claimed.algorithm))
		}

		guard
			let keyData = Data(base64Encoded: claimed.publicKey),
			keyData.count == 32
		else {
			return .claimedButInvalid(reason: .localized("The signing key in this source is not a valid Ed25519 public key."))
		}

		guard
			let signatureData = Data(base64Encoded: claimed.signature),
			signatureData.count == 64
		else {
			return .claimedButInvalid(reason: .localized("The signature in this source is not a valid Ed25519 signature."))
		}

		guard let canonical = canonicalBytes(document) else {
			return .claimedButInvalid(reason: .localized("This source is not a JSON document, so its signature cannot cover anything."))
		}

		guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { // try? ok: an unusable key is reported as an invalid signature below
			return .claimedButInvalid(reason: .localized("The signing key in this source is not usable."))
		}

		guard key.isValidSignature(signatureData, for: canonical) else {
			return .claimedButInvalid(reason: .localized("The signature does not match the contents of this source."))
		}

		return .verified(publisher: claimed.publisher)
	}
}

// MARK: - What was learned about each source

/// The last verdict per source URL, so the repository row can show evidence rather than a toggle.
/// Kept in `UserDefaults` because it is a label, not a security boundary: the check itself happens
/// on every refresh, and a stale label can only ever be too generous for one refresh.
enum SourceProvenanceStore {
	private static let key = "VexSign.sourceProvenance"

	private static func load() -> [String: String] {
		UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
	}

	static func record(_ provenance: SourceProvenance, for url: URL) {
		var stored = load()
		let previous = stored[url.absoluteString]

		switch provenance {
		case .unsigned:
			stored.removeValue(forKey: url.absoluteString)
		case .verified(let publisher):
			stored[url.absoluteString] = publisher.map { "signed:\($0)" } ?? "signed"
		case .claimedButInvalid:
			stored[url.absoluteString] = "invalid"
		}

		// Every refresh passes through here; only write when the answer actually changed.
		guard stored[url.absoluteString] != previous else { return }
		UserDefaults.standard.set(stored, forKey: key)
	}

	static func provenance(for url: URL) -> SourceProvenance? {
		switch load()[url.absoluteString] {
		case .none:
			return nil
		case "invalid":
			return .claimedButInvalid(reason: .localized("The signature does not match the contents of this source."))
		case "signed":
			return .verified(publisher: nil)
		case let value? where value.hasPrefix("signed:"):
			return .verified(publisher: String(value.dropFirst("signed:".count)))
		default:
			return nil
		}
	}

	static func clear() {
		UserDefaults.standard.removeObject(forKey: key)
	}
}
