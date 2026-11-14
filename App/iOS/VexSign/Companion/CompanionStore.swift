//
//  CompanionStore.swift
//  VexSign
//
//  The view model the Apple TV and Apple Vision Pro companions share: it owns the
//  connection settings, the last good snapshot and the refresh loop. Both
//  companions are read-only mirrors of the iPhone — nothing here signs, installs
//  or writes to a library, because neither platform can.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class CompanionStore: ObservableObject {
	static let shared = CompanionStore()

	// MARK: State

	@Published private(set) var snapshot: CompanionSnapshot?
	@Published private(set) var libraryResult: Result<[CompanionLibraryEntry], CompanionClientError>?
	@Published private(set) var updatesResult: Result<[CompanionUpdateEntry], CompanionClientError>?
	@Published private(set) var isRefreshing = false
	@Published private(set) var lastError: String?
	@Published private(set) var credentialIssue: String?
	@Published private(set) var hasUnmigratedCredential = false
	@Published private(set) var certificateTrustError: String?
	@Published private(set) var trustedCertificateFingerprint: String?
	@Published private(set) var lastUpdated: Date?

	// MARK: Connection

	static let addressKey = "VexSign.companion.address"
	static let usernameKey = "VexSign.companion.username"
	static let legacyPasswordKey = "VexSign.companion.password" // legacy plaintext; migrated on launch
	static let legacyTokenKey = "VexSign.companion.token" // legacy plaintext; migrated on launch
	static let passwordKey = legacyPasswordKey
	static let tokenKey = legacyTokenKey
	static let allowInsecureHTTPKey = "VexSign.companion.allowInsecureHTTP"
	static let insecureHTTPKey = allowInsecureHTTPKey

	private static let _passwordAccount = CompanionSecretStore.Account.password
	private static let _tokenAccount = CompanionSecretStore.Account.apiToken
	private static let _credentialService = CompanionSecretStore.service
	private static let _legacyCredentialService = "com.vexsign.secrets"
	private static let _legacyPasswordAccount = "companion.password"
	private static let _legacyTokenAccount = "companion.apiToken"
	private static let _credentialWarning = "Keychain access failed. Previously saved credentials were not deleted; unlock the device and reconnect. New credential changes will not persist until secure storage is available."

	@Published var address: String {
		didSet {
			UserDefaults.standard.set(address, forKey: Self.addressKey)
			pairingFingerprint = ""
			_reloadTrustedCertificate()
		}
	}
	/// Supplied only during explicit TLS pairing; accepted trust is stored in the Keychain.
	@Published var pairingFingerprint: String
	@Published var username: String {
		didSet { UserDefaults.standard.set(username, forKey: Self.usernameKey) }
	}
	@Published var password: String {
		didSet { _persistCredential(password, account: Self._passwordAccount, legacyKey: Self.legacyPasswordKey) }
	}
	@Published var apiToken: String {
		didSet { _persistCredential(apiToken, account: Self._tokenAccount, legacyKey: Self.legacyTokenKey) }
	}
	@Published var allowInsecureHTTP: Bool {
		didSet { UserDefaults.standard.set(allowInsecureHTTP, forKey: Self.allowInsecureHTTPKey) }
	}
	var allowsInsecureHTTP: Bool {
		get { allowInsecureHTTP }
		set { allowInsecureHTTP = newValue }
	}

	/// Seconds between background refreshes; 0 turns the loop off.
	@Published var autoRefreshInterval: Int {
		didSet {
			UserDefaults.standard.set(autoRefreshInterval, forKey: "VexSign.companion.autoRefreshInterval")
			_restartAutoRefresh()
		}
	}

	private var _refreshTask: Task<Void, Never>?
	private var _credentialMigrationRetries = Set<String>()
	private var _credentialWriteRetries = Set<String>()
	private var _unmigratedCredentialAccounts = Set<String>()

	private struct CredentialLoad {
		var value: String
		var needsMigrationRetry: Bool
		var hasUnmigratedLegacyValue: Bool
	}

	private init() {
		let defaults = UserDefaults.standard
		let passwordLoad = Self._loadCredential(
			key: Self.legacyPasswordKey,
			account: Self._passwordAccount,
			defaults: defaults
		)
		let tokenLoad = Self._loadCredential(
			key: Self.legacyTokenKey,
			account: Self._tokenAccount,
			defaults: defaults
		)

		self.address = defaults.string(forKey: Self.addressKey) ?? ""
		self.pairingFingerprint = ""
		self.username = defaults.string(forKey: Self.usernameKey) ?? ""
		self.password = passwordLoad.value
		self.apiToken = tokenLoad.value
		self.allowInsecureHTTP = defaults.bool(forKey: Self.allowInsecureHTTPKey)

		// Split out of the `as?` chain so the optional cast and the default stay
		// readable, and a failed cast cannot hide behind the coalescing operator.
		let storedInterval = defaults.object(forKey: "VexSign.companion.autoRefreshInterval") as? Int
		self.autoRefreshInterval = storedInterval ?? 30

		if passwordLoad.needsMigrationRetry {
			_credentialMigrationRetries.insert(Self._passwordAccount)
		}
		if tokenLoad.needsMigrationRetry {
			_credentialMigrationRetries.insert(Self._tokenAccount)
		}
		if passwordLoad.hasUnmigratedLegacyValue {
			_unmigratedCredentialAccounts.insert(Self._passwordAccount)
		}
		if tokenLoad.hasUnmigratedLegacyValue {
			_unmigratedCredentialAccounts.insert(Self._tokenAccount)
		}
		_refreshCredentialStorageWarning()
		_reloadTrustedCertificate()
	}

	private static func _loadCredential(key: String, account: String, defaults: UserDefaults) -> CredentialLoad {
		do {
			let value = try SecureSecretStore.migrateDefaults(
				key,
				account: account,
				defaults: defaults,
				read: { try Self._readCredential($0) },
				write: { data, account in
					try SecureSecretStore.write(data, account: account, service: Self._credentialService)
				}
			)
			return CredentialLoad(value: value, needsMigrationRetry: false, hasUnmigratedLegacyValue: false)
		} catch {
			// Keep the old plaintext value in memory as a last-resort compatibility
			// path, but never remove it or imply that Keychain migration succeeded.
			let legacyValue = defaults.string(forKey: key) ?? ""
			return CredentialLoad(
				value: legacyValue,
				needsMigrationRetry: true,
				hasUnmigratedLegacyValue: !legacyValue.isEmpty
			)
		}
	}

	/// Read the current Keychain namespace first, then migrate the namespace used by
	/// the earlier PR build. A legacy item is deleted only after its replacement has
	/// been written successfully.
	private static func _legacyCredentialAccount(for account: String) -> String? {
		if account == Self._passwordAccount { return Self._legacyPasswordAccount }
		if account == Self._tokenAccount { return Self._legacyTokenAccount }
		return nil
	}

	private static func _readCredential(_ account: String) throws -> Data? {
		let oldAccount = Self._legacyCredentialAccount(for: account)

		if let current = try SecureSecretStore.read(account, service: _credentialService) {
			if let oldAccount {
				try? SecureSecretStore.delete(oldAccount, service: _legacyCredentialService) // try? ok: a failure leaves only a duplicate legacy item; the current credential is already durable
			}
			return current
		}

		guard let oldAccount,
			  let legacy = try SecureSecretStore.read(oldAccount, service: _legacyCredentialService) else {
			return nil
		}
		try SecureSecretStore.write(legacy, account: account, service: _credentialService)
		try? SecureSecretStore.delete(oldAccount, service: _legacyCredentialService) // try? ok: the replacement is durable; a failure only leaves the old Keychain copy
		return legacy
	}

	private func _persistCredential(_ value: String, account: String, legacyKey: String) {
		_credentialMigrationRetries.remove(account)
		do {
			if value.isEmpty {
				try CompanionSecretStore.delete(account)
			} else {
				try CompanionSecretStore.write(value, account: account)
			}
			if let oldAccount = Self._legacyCredentialAccount(for: account) {
				try? SecureSecretStore.delete(oldAccount, service: Self._legacyCredentialService) // try? ok: new value is durable; a failure leaves only the legacy Keychain copy
			}
			UserDefaults.standard.removeObject(forKey: legacyKey)
			_unmigratedCredentialAccounts.remove(account)
			_credentialWriteRetries.remove(account)
		} catch {
			// Do not put the new value back into UserDefaults. Any prior legacy value
			// remains untouched until the secure write succeeds.
			if let legacyValue = UserDefaults.standard.string(forKey: legacyKey), !legacyValue.isEmpty {
				_unmigratedCredentialAccounts.insert(account)
			}
			_credentialWriteRetries.insert(account)
		}
		_refreshCredentialStorageWarning()
	}

	private func _retryCredentialPersistence() {
		let defaults = UserDefaults.standard
		for account in Array(_credentialMigrationRetries) {
			let key: String
			let currentValue: String
			switch account {
			case Self._passwordAccount:
				key = Self.legacyPasswordKey
				currentValue = password
			case Self._tokenAccount:
				key = Self.legacyTokenKey
				currentValue = apiToken
			default:
				continue
			}

			do {
			let migrated = try SecureSecretStore.migrateDefaults(
				key,
				account: account,
				defaults: defaults,
				read: { try Self._readCredential($0) },
				write: { data, itemAccount in
					try SecureSecretStore.write(data, account: itemAccount, service: Self._credentialService)
				}
			)
			_credentialMigrationRetries.remove(account)
			_unmigratedCredentialAccounts.remove(account)
			if migrated != currentValue {
				if account == Self._passwordAccount {
					password = migrated
				} else {
					apiToken = migrated
				}
			}
		} catch {
			// Leave the legacy value as-is. A later explicit refresh can retry.
		}
		}

		for account in Array(_credentialWriteRetries) {
			switch account {
			case Self._passwordAccount:
				_persistCredential(password, account: account, legacyKey: Self.legacyPasswordKey)
			case Self._tokenAccount:
				_persistCredential(apiToken, account: account, legacyKey: Self.legacyTokenKey)
			default:
				continue
			}
		}
		_refreshCredentialStorageWarning()
	}

	private func _refreshCredentialStorageWarning() {
		hasUnmigratedCredential = !_unmigratedCredentialAccounts.isEmpty
		credentialIssue = _credentialMigrationRetries.isEmpty && _credentialWriteRetries.isEmpty
			? nil
			: Self._credentialWarning
	}

	/// Compatibility name used by the TLS-pairing UI from the earlier PR version.
	var credentialStorageError: String? { credentialIssue }

	private func _reloadTrustedCertificate() {
		let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedAddress.isEmpty else {
			trustedCertificateFingerprint = nil
			certificateTrustError = nil
			return
		}

		do {
			let base = try CompanionClient.baseURL(from: trimmedAddress)
			guard base.scheme?.lowercased() == "https" else {
				trustedCertificateFingerprint = nil
				certificateTrustError = nil
				return
			}
			let pin = try CompanionCertificateTrust.load(for: base)
			trustedCertificateFingerprint = pin?.fingerprint
			certificateTrustError = nil
			if pairingFingerprint.isEmpty, let fingerprint = pin?.fingerprint {
				pairingFingerprint = fingerprint
			}
		} catch let error as CompanionClientError {
			trustedCertificateFingerprint = nil
			if error == .invalidAddress || error == .missingAddress {
				certificateTrustError = nil
			} else {
				certificateTrustError = error.localizedDescription
			}
		} catch {
			trustedCertificateFingerprint = nil
			certificateTrustError = error.localizedDescription
		}
	}

	var isConfigured: Bool {
		!address.trimmingCharacters(in: .whitespaces).isEmpty
	}

	/// HTTP has no certificate pairing; HTTPS requires a manually verified
	/// fingerprint until this exact origin has a saved Keychain pin.
	var requiresCertificatePairing: Bool {
		do {
			let base = try CompanionClient.baseURL(from: address)
			return base.scheme?.lowercased() != "http"
		} catch {
			return true
		}
	}

	var connectButtonTitle: String {
		requiresCertificatePairing && trustedCertificateFingerprint == nil ? "Pair & Connect" : "Connect"
	}

	/// Forgetting is an explicit step before replacing a changed CA fingerprint.
	func forgetTrustedCertificate() {
		do {
			let base = try CompanionClient.baseURL(from: address)
			try CompanionCertificateTrust.forget(for: base)
			trustedCertificateFingerprint = nil
			certificateTrustError = nil
			pairingFingerprint = ""
			lastError = nil
		} catch {
			lastError = error.localizedDescription
		}
	}

	/// HTTPS is the default. It requires a manually verified CA fingerprint on
	/// first connection; HTTP has a separate explicit unencrypted-traffic opt-in.
	var addressHint: String {
		"Use the HTTPS URL and SHA-256 device CA fingerprint shown in VexSign → Settings → Web Manager; pairing is saved in Keychain. The current Web Manager serves HTTPS only. HTTP is for a compatible local-network HTTP server after opting in and is never a fallback."
	}

	// MARK: Refresh

	var client: CompanionClient {
		CompanionClient(
			address: address,
			username: username.isEmpty ? nil : username,
			password: password.isEmpty ? nil : password,
			apiToken: apiToken.isEmpty ? nil : apiToken,
			allowInsecureHTTP: allowInsecureHTTP,
			pairingFingerprint: pairingFingerprint.isEmpty ? nil : pairingFingerprint
		)
	}

	func refresh() async {
		guard !isRefreshing else { return }
		_retryCredentialPersistence()
		guard isConfigured else {
			lastError = CompanionClientError.missingAddress.errorDescription
			return
		}

		isRefreshing = true
		defer { isRefreshing = false }

		do {
			let fetched = try await client.snapshot()
			let previous = snapshot
			snapshot = CompanionSnapshot(
				status: fetched.status,
				library: _successValue(in: fetched.library) ?? previous?.library ?? [],
				updates: _successValue(in: fetched.updates) ?? previous?.updates ?? [],
				generatedAt: fetched.generatedAt
			)
			libraryResult = fetched.library
			updatesResult = fetched.updates
			lastUpdated = fetched.generatedAt
			lastError = nil
		} catch {
			// Keep the previous snapshot on screen: a companion that blanks out
			// every time the phone locks is useless. The error remains visible.
			lastError = error.localizedDescription
		}
		_reloadTrustedCertificate()
	}

	private func _successValue<Value>(in result: Result<Value, CompanionClientError>) -> Value? {
		guard case .success(let value) = result else { return nil }
		return value
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
				try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000) // try? ok: cancellation is checked immediately below
				guard !Task.isCancelled else { return }
				await self?.refresh()
			}
		}
	}
}
