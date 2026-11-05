//
//  WebManager.swift
//  VexSign
//

import Foundation
import UIKit
import OSLog
import NimbleExtensions

/// NSObject because the background notification is delivered through an
/// Objective-C selector; a plain Swift class would not respond to it.
final class WebManager: NSObject, ObservableObject {
	static let shared = WebManager()

	/// UserDefaults keys. `auth` is read by the migration in
	/// `WebManagerSettingsMigration`, which is why they live together.
	enum Keys {
		static let port = "VexSign.webManager.port"
		static let auth = WebManagerSettingsMigration.Key.auth
		static let user = "VexSign.webManager.user"
		static let keepAlive = "VexSign.webManager.keepAlive"
		static let bindMode = "VexSign.webManager.bindMode"
		static let allowUnauthenticatedLAN = "VexSign.webManager.allowUnauthenticatedLAN"
		static let certificateExport = "VexSign.webManager.certificateExport"
		/// Legacy plaintext key, migrated into the Keychain on first launch.
		static let legacyToken = "VexSign.apiToken"
	}

	@Published private(set) var isRunning = false
	@Published private(set) var recentUploads: [String] = []
	@Published var lastError: String?

	/// Set once when an install that ran the server without a password is switched
	/// to authenticated mode, so the change can be explained instead of happening
	/// silently. The view clears it after showing the explanation.
	@Published var needsAuthExplanation = false

	@Published var port: Int {
		didSet { UserDefaults.standard.set(port, forKey: Keys.port) }
	}
	@Published var requireAuth: Bool {
		didSet { UserDefaults.standard.set(requireAuth, forKey: Keys.auth) }
	}
	@Published var username: String {
		didSet { UserDefaults.standard.set(username, forKey: Keys.user) }
	}
	@Published var password: String {
		didSet {
			do { try SecureSecretStore.write(Data(password.utf8), account: "webManager.password") } catch { lastError = "Password could not be saved to Keychain: \(error.localizedDescription)" }
		}
	}
	/// Shared secret for scripts and companion devices. Same reach as the password,
	/// so it lives in the Keychain rather than in UserDefaults.
	@Published var apiToken: String {
		didSet {
			do { try SecureSecretStore.write(Data(apiToken.utf8), account: "webManager.apiToken") } catch { lastError = "API token could not be saved to Keychain: \(error.localizedDescription)" }
		}
	}
	/// Where the server listens. Loopback is the fallback whenever the server has no
	/// password, so "no auth" and "on the network" cannot combine by accident.
	@Published var bindMode: WebManagerBindMode {
		didSet { UserDefaults.standard.set(bindMode.rawValue, forKey: Keys.bindMode) }
	}
	/// Explicit opt-in for an unauthenticated server on the local network.
	@Published var allowUnauthenticatedLAN: Bool {
		didSet { UserDefaults.standard.set(allowUnauthenticatedLAN, forKey: Keys.allowUnauthenticatedLAN) }
	}
	/// Certificate download hands out the private key, so it is opt-in.
	@Published var allowCertificateExport: Bool {
		didSet { UserDefaults.standard.set(allowCertificateExport, forKey: Keys.certificateExport) }
	}
	/// Keep server reachable in background via silent-audio keep-alive.
	@Published var keepAlive: Bool {
		didSet {
			UserDefaults.standard.set(keepAlive, forKey: Keys.keepAlive)
			_applyKeepAlive()
		}
	}

	private var _server: WebManagerServer?
	private var _startTask: Task<Void, Never>?
	private var _keepAliveTask: BackgroundTaskManager?

	// Coalesce a burst of uploads (e.g. a folder copy) into one toast.
	private var _pendingToastCount = 0
	private var _pendingToastName: String?
	private var _toastWork: DispatchWorkItem?

	private override init() {
		let defaults = UserDefaults.standard

		// Runs before `requireAuth` is read: it seeds the key for fresh installs and
		// flips it on once for installs that had the server open.
		let migrated = WebManagerSettingsMigration.migrateAuthDefaultIfNeeded(defaults: defaults)

		self.needsAuthExplanation = migrated
		self.port = defaults.object(forKey: Keys.port) as? Int ?? 8080
		self.requireAuth = defaults.bool(forKey: Keys.auth)
		self.username = defaults.string(forKey: Keys.user) ?? "vex"
		self.password = ""
		self.apiToken = ""
		self.bindMode = WebManagerBindMode(rawValue: defaults.string(forKey: Keys.bindMode) ?? "") ?? .localNetwork
		self.allowUnauthenticatedLAN = defaults.bool(forKey: Keys.allowUnauthenticatedLAN)
		self.allowCertificateExport = defaults.bool(forKey: Keys.certificateExport)
		self.keepAlive = defaults.bool(forKey: Keys.keepAlive)

		do { self.password = try SecureSecretStore.migrateDefaults("VexSign.webManager.pass", account: "webManager.password") } catch { self.lastError = "Unlock the device to migrate the WebDAV password." }
		do { self.apiToken = try SecureSecretStore.migrateDefaults(Keys.legacyToken, account: "webManager.apiToken") } catch { self.lastError = "Unlock the device to migrate the API token." }

		super.init()

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(_didEnterBackground),
			name: UIApplication.didEnterBackgroundNotification,
			object: nil
		)
	}

	// MARK: Lifecycle

	func start() {
		guard !isRunning, _startTask == nil else { return }
		guard !requireAuth || authActive else {
			lastError = String.localized("Set a username and password first, or turn off Require Password to keep the server on this device.")
			return
		}
		lastError = nil

		let auth: WebManagerServer.Auth? = authActive
			? WebManagerServer.Auth(username: username, password: password)
			: nil
		let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)

		let server: WebManagerServer
		do {
			server = try WebManagerServer(
				port: port,
				auth: auth,
				bindMode: effectiveBindMode,
				token: token.isEmpty ? nil : token,
				allowsCertificateExport: allowCertificateExport
			) { [weak self] name in
				DispatchQueue.main.async {
					guard let self else { return }
					self.recentUploads.removeAll { $0 == name }
					self.recentUploads.insert(name, at: 0)
					if self.recentUploads.count > 25 {
						self.recentUploads.removeLast(self.recentUploads.count - 25)
					}
					self._queueReceiveToast(name)
				}
			}
		} catch {
			lastError = error.localizedDescription
			return
		}

		_server = server
		_startTask = Task { @MainActor in
			do {
				try await server.start()
				guard self._server === server else {
					// `stop()` detached us while the server was starting.
					await server.shutdownAsync()
					return
				}
				self._startTask = nil
				self.isRunning = true
				if self.keepAlive { self._startKeepAlive() }
			} catch {
				guard self._server === server else { return }
				self._startTask = nil
				Logger.misc.error("WebManagerServer failed to start: \(error.localizedDescription)")
				self.lastError = error.localizedDescription
				self._server = nil
				self.isRunning = false
			}
		}
	}

	func stop() {
		// A start in flight owns its application; cancelling it makes the task
		// shut the server down asynchronously. Tearing it down here as well
		// would race the Vapor lifecycle.
		if let task = _startTask {
			_startTask = nil
			task.cancel()
			_server = nil
			_stopKeepAlive()
			isRunning = false
			return
		}

		_stopKeepAlive()
		_server?.shutdown()
		_server = nil
		isRunning = false
	}

	func toggle() {
		(isRunning || _startTask != nil) ? stop() : start()
	}

	func clearRecent() {
		recentUploads.removeAll()
	}

	/// Restart so changed settings (port/auth/bind/token) take effect.
	func restartIfRunning() {
		// A start in flight already reads the current settings; restarting it
		// would make two attempts bind the same port.
		guard isRunning else { return }
		stop()
		start()
	}

	/// Password protection is only effective with a username AND a non-empty password.
	var authActive: Bool { requireAuth && !username.isEmpty && !password.isEmpty }

	/// A token is only used when it is non-empty.
	var tokenActive: Bool { !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

	/// The mode actually used - see `WebManagerAccessPolicy.effectiveBindMode`.
	var effectiveBindMode: WebManagerBindMode {
		WebManagerAccessPolicy.effectiveBindMode(
			requested: bindMode,
			authActive: authActive,
			allowUnauthenticatedLAN: allowUnauthenticatedLAN
		)
	}

	/// The bind mode was downgraded from the user's choice.
	var isBindDowngraded: Bool { bindMode != effectiveBindMode }

	// MARK: URLs

	/// LAN address, shown next to the loopback one when it is available.
	var localAddress: String { ServerInstaller.getLocalAddress() ?? "127.0.0.1" }

	/// Host shown in the connection URLs: loopback when the server only listens on
	/// loopback, otherwise the LAN address a peer would dial.
	var displayHost: String {
		effectiveBindMode == .thisDevice ? "127.0.0.1" : localAddress
	}

	var httpURL: String { "http://\(displayHost):\(port)/" }
	var webdavURL: String { "dav://\(displayHost):\(port)/" }

	/// One line the UI can show whenever the server runs, so a running server is
	/// never presented without its exposure.
	var exposureSummary: String {
		let access = authActive
			? String.localized("Password protected")
			: (tokenActive ? String.localized("Token only") : String.localized("No password"))
		let reach = effectiveBindMode == .thisDevice
			? String.localized("this device only")
			: String.localized("this network")
		return "\(access) · \(reach)"
	}

	// MARK: Keep-alive

	private func _applyKeepAlive() {
		if isRunning && keepAlive {
			_startKeepAlive()
		} else {
			_stopKeepAlive()
		}
	}

	private func _startKeepAlive() {
		guard _keepAliveTask == nil else { return }
		let task = BackgroundTaskManager(
			taskName: "WebManager",
			expirationTitle: .localized("Web Manager running"),
			expirationBody: .localized("Reopen VexSign to keep the server reachable.")
		)
		task.start()
		_keepAliveTask = task
	}

	private func _stopKeepAlive() {
		_keepAliveTask?.stop()
		_keepAliveTask = nil
	}

	// MARK: Toasts

	private func _queueReceiveToast(_ name: String) {
		_pendingToastCount += 1
		_pendingToastName = name
		_toastWork?.cancel()

		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			let count = self._pendingToastCount
			let message: String = count <= 1
				? String.localized("Received %@", arguments: self._pendingToastName ?? "file")
				: String.localized("Received %lld items", arguments: count)
			Toast.success(message, systemImage: "tray.and.arrow.down.fill")
			self._pendingToastCount = 0
			self._pendingToastName = nil
		}
		_toastWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
	}

	@objc private func _didEnterBackground() {
		// Keep-alive holds the server up; otherwise background sockets are unreliable, so stop cleanly.
		if keepAlive && isRunning { return }
		stop()
	}
}
