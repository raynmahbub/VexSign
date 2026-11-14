//
//  UnattendedSigningGrant.swift
//  VexSign
//
//  Permission for scheduled work to sign without the user present.
//
//  "Sign & queue" was a preference: set once, it let every later background pass sign with
//  whatever certificate happened to be selected, forever. A grant is narrower on purpose:
//
//    * scope        — what the background may do (today: sign and queue found updates)
//    * certificate  — the one certificate it may do it with
//    * expiry       — at most `maximumLifetime`, after which it stops by itself
//    * revocation   — the user can end it at any time; a revoked grant never revives
//
//  It holds no secret: an identifier, three dates and a scope. The certificate and its key
//  stay where they were. Without an active grant a background pass still checks for updates
//  and notifies; it does not sign.
//
//  This does not renew a free Apple ID profile. That is an account operation with its own
//  approvals, and no scheduled task performs it.
//

import Foundation
import NimbleExtensions

struct UnattendedSigningGrant: Codable, Equatable, Sendable {
	/// What the background may do under a grant.
	enum Scope: String, Codable, CaseIterable, Sendable {
		/// Sign updates found by a scheduled pass and add them to the install queue.
		case signAndQueueUpdates
	}

	/// The lifetimes a user can choose. There is no "forever".
	enum Lifetime: Int, CaseIterable, Identifiable, Sendable {
		case oneDay = 1
		case oneWeek = 7
		case thirtyDays = 30

		var id: Int { rawValue }
		var interval: TimeInterval { TimeInterval(rawValue) * 86_400 }

		var title: String {
			switch self {
			case .oneDay: .localized("1 day")
			case .oneWeek: .localized("7 days")
			case .thirtyDays: .localized("30 days")
			}
		}
	}

	static let maximumLifetime: TimeInterval = Lifetime.thirtyDays.interval

	let id: UUID
	let scope: Scope
	/// The certificate this grant is for. Selecting another one is not covered.
	let certificateUUID: String
	let issuedAt: Date
	let expiresAt: Date
	var revokedAt: Date?

	/// Issues a grant from an explicit user action. Returns nil for a certificate with no
	/// identifier: a grant that names nothing would cover everything.
	static func issue(
		scope: Scope,
		certificateUUID: String,
		lifetime: Lifetime,
		now: Date = Date()
	) -> UnattendedSigningGrant? {
		let certificate = certificateUUID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !certificate.isEmpty else { return nil }
		return UnattendedSigningGrant(
			id: UUID(),
			scope: scope,
			certificateUUID: certificate,
			issuedAt: now,
			expiresAt: now.addingTimeInterval(min(lifetime.interval, maximumLifetime)),
			revokedAt: nil
		)
	}

	// MARK: Decision

	enum Decision: Equatable, Sendable {
		case authorized
		case noGrant
		case revoked
		case expired
		/// The stored dates cannot be a grant this app issued: it starts in the future, ends
		/// before it starts, or runs longer than the maximum.
		case invalid
		case scopeNotCovered
		case differentCertificate

		var isAuthorized: Bool { self == .authorized }

		/// Why the background did not sign, for the automation log and the settings screen.
		var explanation: String {
			switch self {
			case .authorized:
				.localized("Background signing is allowed.")
			case .noGrant:
				.localized("Background signing has not been allowed. Scheduled checks will notify you instead of signing.")
			case .revoked:
				.localized("You turned background signing off. Scheduled checks will notify you instead of signing.")
			case .expired:
				.localized("The permission for background signing has run out. Allow it again to continue.")
			case .invalid:
				.localized("The stored permission is not valid and is ignored. Allow background signing again.")
			case .scopeNotCovered:
				.localized("The permission does not cover this kind of background work.")
			case .differentCertificate:
				.localized("The permission was given for a different certificate. Allow background signing again for the selected one.")
			}
		}
	}

	/// Whether `grant` allows `scope` with `certificateUUID` at `now`.
	///
	/// Order matters: revocation outranks everything, so a revoked grant reads as revoked
	/// even after it would have expired.
	static func decision(
		grant: UnattendedSigningGrant?,
		scope: Scope,
		certificateUUID: String?,
		now: Date = Date()
	) -> Decision {
		guard let grant else { return .noGrant }
		if grant.revokedAt != nil { return .revoked }
		// A little slack for a clock corrected backwards; not enough to pre-date a grant.
		guard grant.issuedAt <= now.addingTimeInterval(300),
		      grant.expiresAt > grant.issuedAt,
		      grant.expiresAt.timeIntervalSince(grant.issuedAt) <= maximumLifetime + 1 else {
			return .invalid
		}
		guard now < grant.expiresAt else { return .expired }
		guard grant.scope == scope else { return .scopeNotCovered }
		guard let certificateUUID, !certificateUUID.isEmpty, certificateUUID == grant.certificateUUID else {
			return .differentCertificate
		}
		return .authorized
	}
}

// MARK: - Store

/// Where the one current grant lives. Stateless: every call reads the defaults it is given.
enum UnattendedSigningGrantStore {
	static let key = "VexSign.automation.unattendedSigningGrant"

	static func current(defaults: UserDefaults = .standard) -> UnattendedSigningGrant? {
		guard let data = defaults.data(forKey: key) else { return nil }
		do {
			return try JSONDecoder().decode(UnattendedSigningGrant.self, from: data)
		} catch {
			// An unreadable grant authorizes nothing.
			FileLogger.error("Stored background-signing permission could not be read: \(error.localizedDescription)", category: "update")
			return nil
		}
	}

	/// Replaces any earlier grant. Returns false when it could not be stored.
	@discardableResult
	static func save(_ grant: UnattendedSigningGrant, defaults: UserDefaults = .standard) -> Bool {
		do {
			defaults.set(try JSONEncoder().encode(grant), forKey: key)
			return true
		} catch {
			FileLogger.error("Background-signing permission could not be stored: \(error.localizedDescription)", category: "update")
			return false
		}
	}

	/// Ends the current grant. The record is kept, marked revoked, so the screen can say that
	/// it was turned off rather than that it never existed.
	static func revoke(now: Date = Date(), defaults: UserDefaults = .standard) {
		guard var grant = current(defaults: defaults), grant.revokedAt == nil else { return }
		grant.revokedAt = now
		if !save(grant, defaults: defaults) {
			// If the revocation cannot be written, removing the grant still ends it.
			defaults.removeObject(forKey: key)
		}
	}

	static func decision(
		scope: UnattendedSigningGrant.Scope,
		certificateUUID: String?,
		now: Date = Date(),
		defaults: UserDefaults = .standard
	) -> UnattendedSigningGrant.Decision {
		UnattendedSigningGrant.decision(
			grant: current(defaults: defaults), scope: scope, certificateUUID: certificateUUID, now: now
		)
	}
}
