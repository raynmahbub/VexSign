//
//  SelfUpdateManager.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation
import CoreData
import UIKit
import IDeviceSwift
import OSLog
import NimbleExtensions

enum SelfUpdateMethod: Int {
	case server = 0
	case idevice = 1

	var title: String {
		switch self {
		case .server: return .localized("Server")
		case .idevice: return .localized("IDevice")
		}
	}
}

// MARK: - Readiness

/// Why the selected self-update method cannot install right now.
///
/// The sheet used to discover this only after the user tapped Install, and answered with a single
/// sentence that named no cause and no way out. The plan is evaluated before the tap so the sheet
/// can say what is missing and, when the other method is ready, offer it.
enum SelfUpdateBlocker: String, Equatable {
	/// The build embeds its own VexSign; a plain VexSign IPA cannot replace the combined runtime.
	case combinedHost
	/// No updater server address in this build and none configured by the user.
	case serverNotConfigured
	/// The IDevice route needs a pairing file on disk.
	case pairingMissing
	/// The release has no IPA asset, so IDevice has nothing to download.
	case noDownload
    /// A remote updater must never receive the user's signing key/password.
    case remoteSigningDisabled
    /// Self replacement requires supported transport and exact-version evidence.
    case pairedRouteUnavailable

    /// No picker change can enable self replacement in this build. In particular
    /// do not route someone from missing pairing into remote key upload.
    var isFinal: Bool { true }

	var message: String {
		switch self {
		case .combinedHost:
			return .localized("Install a verified combined-host update. A standalone VexSign IPA cannot update this combined runtime.")
		case .serverNotConfigured:
			return .localized("No legacy updater address is configured. Remote self-update signing is disabled in this build even with an address; download the IPA and use local signing with an eligible external installer.")
		case .pairingMissing:
			return .localized("No pairing record was found. Review device bootstrap for compatible import and transport requirements. Paired self-update remains gated; use an eligible external installer.")
		case .noDownload:
			return .localized("This release has no downloadable IPA. Choose a release with an IPA and use local signing or an eligible external installer.")
        case .remoteSigningDisabled:
            return .localized("Remote self-update signing is disabled: VexSign does not upload your certificate, private key or password to an updater. Download the release IPA, sign locally in Library, and use an eligible external installer to update VexSign.")
        case .pairedRouteUnavailable:
            return .localized("Paired self-update is unavailable in this build. It requires accepted same-device inventory, exact installed-version evidence and a supported self-replacement lifecycle. A pairing file, VPN or private suspend selector cannot supply those guarantees. Use an eligible external installer.")
		}
	}
}

/// The verdict for one attempt: which method would run, what stops it, and what else would work.
struct SelfUpdatePlan: Equatable {
	let method: SelfUpdateMethod
	let blocker: SelfUpdateBlocker?
	/// The other method, when it is ready right now.
	let alternative: SelfUpdateMethod?

	var canInstall: Bool { blocker == nil }
}

struct SelfUpdateRelease: Identifiable, Equatable {
	let id: Int
	let tag: String
	let version: String
	let title: String
	let notes: String
	let publishedAt: Date?
	let downloadURL: URL?
	let isPrerelease: Bool
	let isSemver: Bool

	var isInstalled: Bool { SelfUpdateManager.compare(version, Bundle.main.version) == .orderedSame }
}

enum SelfUpdatePhase: Equatable {
	case idle
	case downloading(Double)
	case importing
	case signing
	case installing
	case done
	case failed(String)
}

final class SelfUpdateManager: NSObject, ObservableObject {
	static let shared = SelfUpdateManager()

	@Published private(set) var latest: SelfUpdateRelease?
	@Published private(set) var latestSemver: SelfUpdateRelease?
	@Published private(set) var available: SelfUpdateRelease?
	@Published private(set) var isChecking = false
	@Published private(set) var hasChecked = false
	@Published private(set) var checkError: String?
	@Published var phase: SelfUpdatePhase = .idle
	@Published var installProgress: Double = 0
	@Published var presentUpdatePrompt = false

	private let _repo = "raynmahbub/VexSign"
	private let _perPage = 30

	private enum Keys {
		static let autoCheck = "VexSign.selfUpdateAutoCheck"
		static let ignored = "VexSign.selfUpdateIgnored"
		static let certIndex = "VexSign.selfUpdateCertIndex"
		static let lastCheck = "VexSign.selfUpdateLastCheck"
		static let method = "VexSign.selfUpdateMethod"
		static let serverURL = "VexSign.selfUpdateServerURL"
	}

	private var _flow: Task<Void, Never>?

	private override init() {
		super.init()
		UserDefaults.standard.register(defaults: [Keys.autoCheck: true, Keys.certIndex: -1])
	}

	// MARK: - Settings

	var isAutoCheckEnabled: Bool {
		get { UserDefaults.standard.bool(forKey: Keys.autoCheck) }
		set { UserDefaults.standard.set(newValue, forKey: Keys.autoCheck) }
	}

	var certIndex: Int {
		get { UserDefaults.standard.integer(forKey: Keys.certIndex) }
		set { UserDefaults.standard.set(newValue, forKey: Keys.certIndex); objectWillChange.send() }
	}

	var ignoredVersions: Set<String> {
		Set(UserDefaults.standard.stringArray(forKey: Keys.ignored) ?? [])
	}

	func resolvedCertificate() -> CertificatePair? {
		let idx = certIndex >= 0 ? certIndex : UserDefaults.standard.integer(forKey: "vexsign.selectedCert")
		return Storage.shared.getCertificate(for: idx)
	}

	var method: SelfUpdateMethod {
		get { SelfUpdateMethod(rawValue: UserDefaults.standard.integer(forKey: Keys.method)) ?? .server }
		set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.method); objectWillChange.send() }
	}

	var serverBaseURL: URL? {
		if let configured = UserDefaults.standard.string(forKey: Keys.serverURL),
		   let url = Self.normalizedServerBaseURL(configured) {
			return url
		}
		guard
			let url = Bundle.main.url(forResource: "SelfUpdateConfig", withExtension: "plist"),
			let dict = NSDictionary(contentsOf: url),
			let base = dict["ServerBaseURL"] as? String
		else { return nil }
		return Self.normalizedServerBaseURL(base)
	}

	var isServerConfigured: Bool { serverBaseURL != nil }

	/// What the Settings screen shows in its address field: the user override when there is one,
	/// otherwise the bundled address, so a working build does not look unconfigured.
	var configuredServerAddress: String {
		if let configured = UserDefaults.standard.string(forKey: Keys.serverURL),
		   !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return configured
		}
		return serverBaseURL?.absoluteString ?? ""
	}

	var hasServerAddressOverride: Bool {
		guard let raw = UserDefaults.standard.string(forKey: Keys.serverURL) else { return false }
		return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	/// Stores the address Settings collected. An empty string clears the override and lets a
	/// bundled `SelfUpdateConfig.plist` apply again. Returns false for a value that could never
	/// serve `vexsign/sign`, instead of saving it and failing later with a network error.
	@discardableResult
	func setServerBaseURL(_ raw: String?) -> Bool {
		let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty {
			UserDefaults.standard.removeObject(forKey: Keys.serverURL)
			objectWillChange.send()
			return true
		}
		guard let url = Self.normalizedServerBaseURL(trimmed) else { return false }
		UserDefaults.standard.set(url.absoluteString, forKey: Keys.serverURL)
		objectWillChange.send()
		return true
	}

	/// A scheme-less host ("updater.example.com") is what people type, so https is assumed. Anything
	/// that is not an absolute http(s) URL with a host is rejected: a stray value in this key used to
	/// make `isServerConfigured` true and then fail during the upload with an opaque error.
	static func normalizedServerBaseURL(_ raw: String) -> URL? {
		var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return nil }
		// A space anywhere means a pasted sentence or a broken paste, not an address. Rejecting it
		// here is deterministic; URLComponents would quietly percent-encode some of them.
		guard !text.contains(where: { $0.isWhitespace }) else { return nil }
		if !text.contains("://") { text = "https://" + text }
		while text.hasSuffix("/") { text.removeLast() }
		guard
			!text.isEmpty,
			let components = URLComponents(string: text),
			let scheme = components.scheme?.lowercased(),
			scheme == "http" || scheme == "https",
			let host = components.host,
			!host.isEmpty, components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
		else { return nil }
		return components.url
	}

	/// Re-reads the things readiness depends on (pairing file, server address) and republishes.
	func refreshConfiguration() { objectWillChange.send() }

	var hasPairing: Bool {
		FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())
	}

	// MARK: - Plan

	/// Pure: every input is passed in, so the decision is testable without a device.
	static func plan(
		preferred: SelfUpdateMethod,
		isPrimaryHost: Bool,
		serverConfigured: Bool,
		hasPairing: Bool,
		hasDownload: Bool
	) -> SelfUpdatePlan {
		guard !isPrimaryHost else {
			return SelfUpdatePlan(method: preferred, blocker: .combinedHost, alternative: nil)
		}

        // Configuration/file presence never grants permission to export keys,
        // authorize a native mutation, or call a command acknowledgement installed.
        let blocker: SelfUpdateBlocker
        switch preferred {
        case .server:
            blocker = .remoteSigningDisabled
        case .idevice:
            if !hasDownload { blocker = .noDownload }
            else if !hasPairing { blocker = .pairingMissing }
            else { blocker = .pairedRouteUnavailable }
        }
        return SelfUpdatePlan(method: preferred, blocker: blocker, alternative: nil)
    }

	/// The plan for the current device and configuration. `release` is optional because the Settings
	/// screen asks "could this work at all?" before a release is chosen.
	func plan(for release: SelfUpdateRelease?) -> SelfUpdatePlan {
		Self.plan(
			preferred: method,
			isPrimaryHost: EmbeddedContainerRuntime.isPrimaryHost,
			serverConfigured: isServerConfigured,
			hasPairing: hasPairing,
			hasDownload: release.map { $0.downloadURL != nil } ?? true
		)
	}

	var canSelfInstall: Bool { plan(for: nil).canInstall }

	/// Switch methods from the sheet and keep the publication honest.
	func adopt(_ newMethod: SelfUpdateMethod) {
		guard newMethod != method else { return }
		method = newMethod
		phase = .idle
		installProgress = 0
		FileLogger.log("Update method switched to \(newMethod.title)", category: "update")
	}

	func ignore(_ version: String) {
		var set = ignoredVersions
		set.insert(version)
		UserDefaults.standard.set(Array(set), forKey: Keys.ignored)
		recomputeAvailable()
	}

	func unignore(_ version: String) {
		var set = ignoredVersions
		set.remove(version)
		UserDefaults.standard.set(Array(set), forKey: Keys.ignored)
		recomputeAvailable()
	}

	// MARK: - Check

	@MainActor
	func checkOnLaunch() async {
		guard isAutoCheckEnabled else { return }
		// The launch check is the one request VexSign makes without being asked, so it is part
		// of what Game Mode stops. The manual check in Settings still works.
		guard !GameMode.isEnabled else { return }
		await check()
		if let release = available {
			presentUpdatePrompt = true
			// The prompt is the announcement; remember it so a dismissed prompt can still be
			// delivered as a notification by the next check.
			SelfUpdateNotifier.noteSurfaced(release.version)
		}
	}

	@MainActor
	func check() async {
		guard !isChecking else { return }
		isChecking = true
		checkError = nil
		defer { isChecking = false }

		do {
			let releases = try await fetchReleases(page: 1)
			latest = releases.first { !$0.isPrerelease } ?? releases.first
			latestSemver = releases.first { $0.isSemver && !$0.isPrerelease }
			hasChecked = true
			checkError = nil
			UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)
			recomputeAvailable()
			// Announce a release once, the first time this build sees it.
			if let candidate = available {
				await SelfUpdateNotifier.notifyIfNeeded(candidate)
			}
		} catch {
			hasChecked = true
			checkError = error.localizedDescription
			Logger.misc.error("Self-update check failed: \(error.localizedDescription)")
		}
	}

	private func recomputeAvailable() {
		guard let candidate = latestSemver, Self.isSemver(Bundle.main.version) else { available = nil; return }
		let isNewer = SelfUpdateManager.compare(candidate.version, Bundle.main.version) == .orderedDescending
		available = (isNewer && !ignoredVersions.contains(candidate.version)) ? candidate : nil
	}

	// MARK: - Releases fetch (paginated)

	func fetchReleases(page: Int) async throws -> [SelfUpdateRelease] {
		guard var comps = URLComponents(string: "https://api.github.com/repos/\(_repo)/releases"),
		      comps.url != nil else {
			throw NSError(domain: "SelfUpdate", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid GitHub API URL"])
		}
		comps.queryItems = [
			URLQueryItem(name: "per_page", value: String(_perPage)),
			URLQueryItem(name: "page", value: String(page))
		]
		guard let finalURL = comps.url else {
			throw NSError(domain: "SelfUpdate", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid GitHub API URL with query"])
		}
		var request = URLRequest(url: finalURL)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		// A page that never answers would leave the update screen spinning with no way out.
		// `URLSession.shared`'s default is 60 s per page, multiplied by however many pages
		// GitHub reports.
		request.timeoutInterval = 20

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
			throw NSError(domain: "SelfUpdate", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
						  userInfo: [NSLocalizedDescriptionKey: String.localized("Couldn't reach GitHub releases.")])
		}

		let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
		return raw.compactMap(Self.parse)
	}

	private static func parse(_ json: [String: Any]) -> SelfUpdateRelease? {
		guard
			let id = json["id"] as? Int,
			let tag = json["tag_name"] as? String
		else { return nil }

		let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
		guard version.first?.isNumber == true else { return nil }

		let assets = json["assets"] as? [[String: Any]] ?? []
		let ipa = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }
		// `URL(string:)` spelled out: an unapplied `URL.init` grows new overloads with
		// every SDK, and the newer ones make it ambiguous at a newer deployment target.
		let downloadURL = (ipa?["browser_download_url"] as? String).flatMap { URL(string: $0) }

		var published: Date?
		if let str = json["published_at"] as? String {
			published = ISO8601DateFormatter().date(from: str)
		}

		return SelfUpdateRelease(
			id: id,
			tag: tag,
			version: version,
			title: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
			notes: (json["body"] as? String) ?? "",
			publishedAt: published,
			downloadURL: downloadURL,
			isPrerelease: (json["prerelease"] as? Bool) ?? false,
			isSemver: Self.isSemver(version)
		)
	}

	static func isSemver(_ version: String) -> Bool {
		version.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil
	}

	// MARK: - Version compare

	static func compare(_ a: String, _ b: String) -> ComparisonResult {
		// The shared comparator first: it knows `V1.3` from `1.3`, orders a prerelease below
		// its release and ignores build metadata. The dotted-integer comparison below treated
		// `1.3.0-beta` as `1.3.0.0` (equal to the release) and any `v`-prefixed component as 0.
		// It stays as the fallback for strings the shared comparator does not accept.
		if let order = VersionOrder.precedence(a, b) { return order }
		func parts(_ s: String) -> [Int] {
			s.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
		}
		let l = parts(a), r = parts(b)
		for i in 0..<max(l.count, r.count) {
			let lv = i < l.count ? l[i] : 0
			let rv = i < r.count ? r[i] : 0
			if lv != rv { return lv < rv ? .orderedAscending : .orderedDescending }
		}
		return .orderedSame
	}

	// MARK: - Install

	/// One cancellable task per run, cancelling on sheet dismiss stops the poll republishing
	@MainActor
	func beginUpdate(to release: SelfUpdateRelease) {
		_flow?.cancel()
		_flow = Task { await performUpdate(to: release) }
	}

	@MainActor
	func endFlow() {
		_flow?.cancel()
		_flow = nil
		// A failure belongs to the attempt, not to the sheet: keeping it here made the next open
		// show a stale error before anything was tried.
		phase = .idle
		installProgress = 0
	}

    @MainActor
    func performUpdate(to release: SelfUpdateRelease) async {
        let blocker = plan(for: release).blocker ?? .pairedRouteUnavailable
        phase = .failed(blocker.message)
        // No certificate lookup/export, private progress probe, undocumented
        // suspend invocation, automatic method switch, or signing-key upload.
        FileLogger.log("Self-update blocked [\(blocker.rawValue)]; use local signing and an eligible external installer.", category: "update")
    }
}
