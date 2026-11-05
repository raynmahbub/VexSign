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
	@Published private(set) var isRefreshing = false
	@Published private(set) var lastError: String?
	@Published private(set) var lastUpdated: Date?

	// MARK: Connection

	static let addressKey = "VexSign.companion.address"
	static let usernameKey = "VexSign.companion.username"
	static let passwordKey = "VexSign.companion.password"
	static let tokenKey = "VexSign.companion.token"

	@Published var address: String {
		didSet { UserDefaults.standard.set(address, forKey: Self.addressKey) }
	}
	@Published var username: String {
		didSet { UserDefaults.standard.set(username, forKey: Self.usernameKey) }
	}
	@Published var password: String {
		didSet { UserDefaults.standard.set(password, forKey: Self.passwordKey) }
	}
	@Published var apiToken: String {
		didSet { UserDefaults.standard.set(apiToken, forKey: Self.tokenKey) }
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
		self.password = defaults.string(forKey: Self.passwordKey) ?? ""
		self.apiToken = defaults.string(forKey: Self.tokenKey) ?? ""

		// Split out of the `as?` chain so the optional cast and the default stay
		// readable, and a failed cast cannot hide behind the coalescing operator.
		let storedInterval = defaults.object(forKey: "VexSign.companion.autoRefreshInterval") as? Int
		self.autoRefreshInterval = storedInterval ?? 30
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
			apiToken: apiToken.isEmpty ? nil : apiToken
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
				try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
				guard !Task.isCancelled else { return }
				await self?.refresh()
			}
		}
	}
}
