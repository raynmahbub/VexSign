//
//  CompanionStore.swift
//  VexSign
//
//  The view model the Apple TV and Apple Vision Pro companions share: it owns the
//  connection settings, the last good snapshot and the refresh loop. Both
//  companions are read-only mirrors of the iPhone — nothing here signs, installs
//  or writes to a library, because neither platform can.
//
//  Credentials (the Web Manager password and the API token) live in the Keychain
//  through `CompanionSecretStore`, not in `UserDefaults`: a password and a token
//  that grant the same access as the in-app Web Manager must not sit in every
//  preferences dump and backup. The address and username stay in `UserDefaults`,
//  because neither is a secret and losing them on a Keychain failure would make
//  the connection screen reset for no reason.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class CompanionStore: ObservableObject {
	static let shared = CompanionStore()

	// MARK: State

	@Published private(set) var snapshot: CompanionSnapshot?
	@Published private(set) var isRefreshing = false
	@Published private(set) var lastError: String?
	@Published private(set) var lastUpdated: Date?

	/// Why a credential could not be read or written, if one could not be.
	///
	/// It is separate from `lastError` (a refresh failure) because the two need
	/// different answers: a locked Keychain resolves by unlocking the device, a
	/// refused connection does not.
	@Published private(set) var credentialIssue: String?

	/// True when a legacy plaintext credential is still in `UserDefaults` because
	/// the Keychain was unavailable. Surfaced so the UI can ask for a re-entry
	/// instead of pretending the saved value is secure.
	@Published private(set) var hasUnmigratedCredential = false

	// MARK: Connection

	static let addressKey = "VexSign.companion.address"
	static let usernameKey = "VexSign.companion.username"
	/// Legacy plaintext keys, migrated into the Keychain on first launch.
	static let passwordKey = "VexSign.companion.password"
	static let tokenKey = "VexSign.companion.token"

	/// The LAN address a companion can reach locally. Off until the user says so.
	static let allowInsecureHTTPKey = "VexSign.companion.allowInsecureHTTP"

	@Published var address: String {
		didSet { UserDefaults.standard.set(address, forKey: Self.addressKey) }
	}
	@Published var username: String {
		didSet { UserDefaults.standard.set(username, forKey: Self.usernameKey) }
	}

	/// The Web Manager password. Persisted in the Keychain only.
	///
	/// There is deliberately no `didSet` write to `UserDefaults`: keeping the last
	/// value in memory for this session is enough, and every persist goes through
	/// `_store` so a failure is reported rather than lost.
	@Published var password: String {
		didSet { if password != oldValue { _store(password, account: CompanionSecretStore.Account.password) } }
	}

	/// The Web Manager API token. Keychain only, for the same reason.
	@Published var apiToken: String {
		didSet { if apiToken != oldValue { _store(apiToken, account: CompanionSecretStore.Account.apiToken) } }
	}

	/// Plaintext HTTP is only acceptable on a network the user trusts — a home LAN
	/// where the iPhone is reachable by IP address. It stays off by default and the
	/// connect screens state what it means.
	@Published var allowInsecureHTTP: Bool {
		didSet { UserDefaults.standard.set(allowInsecureHTTP, forKey: Self.allowInsecureHTTPKey) }
	}

	/// Seconds between background refreshes; 0 turns the loop off.
	@Published var autoRefreshInterval: Int {
		didSet {
			UserDefaults.standard.set(autoRefreshInterval, forKey: "VexSign.companion.autoRefreshInterval")
			_restartAutoRefresh()
		}
	}

	private var _refreshTask: Task<Void, Never>?

	private init() {
		let defaults = UserDefaults.standard
		self.address = defaults.string(forKey: Self.addressKey) ?? ""
		self.username = defaults.string(forKey: Self.usernameKey) ?? ""
		self.allowInsecureHTTP = defaults.bool(forKey: Self.allowInsecureHTTPKey)
		self.password = ""
		self.apiToken = ""

		// Split out of the `as?` chain so the optional cast and the default stay
		// readable, and a failed cast cannot hide behind the coalescing operator.
		let storedInterval = defaults.object(forKey: "VexSign.companion.autoRefreshInterval") as? Int
		self.autoRefreshInterval = storedInterval ?? 30

		_loadCredentials()
	}

	/// Reads both credentials from the Keychain, migrating legacy plaintext first.
	///
	/// Assignments here run after `init` stored the empty defaults, so the `didSet`
	/// hooks fire; they compare against the previous value and therefore do not
	/// rewrite a value that was just read.
	private func _loadCredentials() {
		var issues: [String] = []

		do {
			self.password = try CompanionSecretStore.migrate(
				legacyKey: Self.passwordKey, account: CompanionSecretStore.Account.password)
		} catch {
			issues.append(Self._describe(error, what: "password"))
			// A locked Keychain is not an empty credential: fall back to the legacy copy so
			// this launch can still connect, and keep it for the next attempt.
			self.password = UserDefaults.standard.string(forKey: Self.passwordKey) ?? ""
			hasUnmigratedCredential = hasUnmigratedCredential || !self.password.isEmpty
		}

		do {
			self.apiToken = try CompanionSecretStore.migrate(
				legacyKey: Self.tokenKey, account: CompanionSecretStore.Account.apiToken)
		} catch {
			issues.append(Self._describe(error, what: "API token"))
			self.apiToken = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
			hasUnmigratedCredential = hasUnmigratedCredential || !self.apiToken.isEmpty
		}

		credentialIssue = issues.isEmpty ? nil : issues.joined(separator: " ")
	}

	/// Persists one credential. An empty value deletes the Keychain item, so clearing
	/// a field does not leave the old secret behind.
	private func _store(_ value: String, account: String) {
		do {
			if value.isEmpty {
				try CompanionSecretStore.delete(account)
			} else {
				try CompanionSecretStore.write(value, account: account)
			}
			credentialIssue = nil
			hasUnmigratedCredential = false
		} catch {
			// Reported, never logged with the value. The in-memory value still works for
			// this session, which is why the connect button keeps working.
			let what = account == CompanionSecretStore.Account.password ? "password" : "API token"
			credentialIssue = Self._describe(error, what: what)
		}
	}

	private static func _describe(_ error: Error, what: String) -> String {
		let detail = (error as? CompanionSecretError)?.message
			?? "The \(what) could not be stored securely."
		return "\(what.capitalized) not saved: \(detail)"
	}

	var isConfigured: Bool {
		!address.trimmingCharacters(in: .whitespaces).isEmpty
	}

	/// The Web Manager prints its own address; this is the hint shown next to the
	/// field so nobody has to guess the port.
	var addressHint: String {
		"http://<iphone-address>:<port> — see Settings → Web Manager in VexSign"
	}

	// MARK: Refresh

	var client: CompanionClient {
		CompanionClient(
			address: address,
			username: username.isEmpty ? nil : username,
			password: password.isEmpty ? nil : password,
			apiToken: apiToken.isEmpty ? nil : apiToken,
			allowInsecureHTTP: allowInsecureHTTP
		)
	}

	func refresh() async {
		guard isConfigured else {
			lastError = CompanionClientError.missingAddress.errorDescription
			return
		}
		guard !isRefreshing else { return }

		isRefreshing = true
		defer { isRefreshing = false }

		do {
			let fetched = try await client.snapshot()
			snapshot = fetched
			lastUpdated = Date()
			lastError = nil
		} catch {
			// Keep the previous snapshot on screen: a companion that blanks out
			// every time the phone locks is useless.
			lastError = error.localizedDescription
		}
	}

	/// First refresh when a scene appears.
	func connectIfNeeded() {
		if snapshot == nil {
			Task { await refresh() }
		}
		_restartAutoRefresh()
	}

	// MARK: Auto refresh

	private func _restartAutoRefresh() {
		_refreshTask?.cancel()
		let interval = autoRefreshInterval
		guard interval > 0 else {
			_refreshTask = nil
			return
		}

		_refreshTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000) // try? ok: cancellation ends the loop below
				guard !Task.isCancelled else { return }
				await self?.refresh()
			}
		}
	}
}
