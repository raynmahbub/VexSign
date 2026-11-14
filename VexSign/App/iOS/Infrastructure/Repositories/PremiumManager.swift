//
//  PremiumManager.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation
import AltSourceKit
import OSLog
import NimbleExtensions

@MainActor
final class PremiumManager: ObservableObject {
	static let shared = PremiumManager()

	enum PremiumError: LocalizedError {
		case noDeviceID
		case notActivated
		case unavailable
		case empty
		case message(String)

		var errorDescription: String? {
			switch self {
			case .noDeviceID: return "Unable to retrieve device identifier. Please try again."
			case .notActivated: return .localized("No premium access is registered for this device ID.")
			case .unavailable: return .localized("Device recovery isn't available on the server yet.")
			case .empty: return "Failed to fetch repository data from the provided URLs."
			case .message(let message): return message
			}
		}
	}

	@Published private(set) var isWorking = false
	@Published private(set) var isActive = false
	@Published private(set) var sourceCount = 0

	private init() {
		refresh()
	}

	func refresh() {
		isActive = VexSignAPI.isPremium && !VexSignAPI.premiumSourceHosts.isEmpty
		sourceCount = Storage.shared.getSources().filter { source in
			source.sourceURL.map { VexSignAPI.isPremiumSource($0) } ?? false
		}.count
	}

	func redeem(key: String) async throws -> Int {
		// Self-managed / local mode: validate against the developer's own key and
		// repo list instead of calling https://vexsign.com. Kept fully offline so
		// a locally generated key works without the official backend.
		if !VexSignAPI.localModePremiumKey.isEmpty {
			guard key == VexSignAPI.localModePremiumKey else {
				throw PremiumError.message("Invalid API key. The key does not exist or has already been used.")
			}
			let urls = VexSignAPI.localModePremiumURLs.compactMap { URL(string: $0) }
			guard !urls.isEmpty else {
				throw PremiumError.message("Local premium mode is enabled but no premium repositories are configured.")
			}
			isWorking = true
			defer { isWorking = false }
			return try await _activate(with: urls)
		}

		guard let endpoint = URL(string: VexSignAPI.apiValidateEndpoint) else {
			throw PremiumError.message("Internal error: Invalid API URL configuration.")
		}

		guard let deviceUUID = VexSignAPI.deviceUUID else { throw PremiumError.noDeviceID }

		guard let body = try? JSONSerialization.data(withJSONObject: ["device_uuid": deviceUUID]) else {
			throw PremiumError.message("Internal error: Failed to prepare request.")
		}

		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.setValue(key, forHTTPHeaderField: "X-API-Key")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = body

		isWorking = true
		defer { isWorking = false }

		let urls = try await _requestURLs(request, missingAccess: "Invalid API key. The key does not exist or has already been used.")
		return try await _activate(with: urls)
	}

	func restore() async throws -> Int {
		isWorking = true
		defer { isWorking = false }

		guard let urls = VexSignAPI.getSavedPremiumURLs() else {
			return try await _recover()
		}

		return try await _activate(with: urls)
	}

	func recoverFromServer() async throws -> Int {
		isWorking = true
		defer { isWorking = false }

		return try await _recover()
	}

	func reset() {
		let hosts = VexSignAPI.premiumSourceHosts

		for source in Storage.shared.getSources() {
			guard
				let url = source.sourceURL,
				let host = url.host?.lowercased(),
				hosts.contains(host)
			else {
				continue
			}

			Storage.shared.deleteSource(for: source)
		}

		VexSignAPI.premiumSourceHosts = []
		VexSignAPI.clearPremiumIdentity()
		refresh()
	}

	private func _recover() async throws -> Int {
		// Self-managed / local mode: recover without any server round-trip.
		if !VexSignAPI.localModePremiumKey.isEmpty {
			let urls = VexSignAPI.localModePremiumURLs.compactMap { URL(string: $0) }
			guard !urls.isEmpty else { throw PremiumError.unavailable }
			return try await _activate(with: urls)
		}

		guard let uuid = VexSignAPI.deviceUUID else { throw PremiumError.noDeviceID }
		guard let endpoint = URL(string: VexSignAPI.apiURLsEndpoint) else { throw PremiumError.unavailable }

		var request = URLRequest(url: endpoint)
		request.setValue(uuid, forHTTPHeaderField: "vexSignUUID")

		let urls = try await _requestURLs(request, missingAccess: PremiumError.notActivated.localizedDescription)
		return try await _activate(with: urls)
	}

	private func _requestURLs(_ request: URLRequest, missingAccess: String) async throws -> [URL] {
		var request = request
		// Render's free tier sleeps after 15 min idle and cold-starts in
		// 30-60s; 30s turned every first-after-idle redeem into a timeout.
		request.timeoutInterval = 90

		let data: Data
		let response: URLResponse

		do {
			(data, response) = try await URLSession.shared.data(for: request)
		} catch let error as URLError {
			Logger.misc.error("Premium API network error: \(error.localizedDescription, privacy: .public)")

			switch error.code {
			case .notConnectedToInternet:
				throw PremiumError.message("No internet connection. Please check your network and try again.")
			case .timedOut:
				throw PremiumError.message("Request timed out. Please check your connection and try again.")
			case .cannotFindHost, .cannotConnectToHost:
				throw PremiumError.message("Cannot connect to VexSign server. Please try again later.")
			default:
				throw PremiumError.message("Network error: \(error.localizedDescription)")
			}
		}

		guard let http = response as? HTTPURLResponse else {
			throw PremiumError.message("Unexpected response from server. Please try again.")
		}

		let detail = try? JSONDecoder().decode(VexSignAPI.ErrorResponse.self, from: data).detail

		switch http.statusCode {
		case 200:
			break
		case 401:
			throw PremiumError.message(detail ?? missingAccess)
		case 403:
			throw PremiumError.message(detail ?? "This API key has been disabled.")
		case 404, 405, 501:
			throw PremiumError.unavailable
		case 422:
			throw PremiumError.message(detail ?? "Request validation failed.")
		case 500...599:
			throw PremiumError.message("VexSign server is currently unavailable (Error \(http.statusCode)). Please try again later.")
		default:
			throw PremiumError.message("Unexpected error (HTTP \(http.statusCode)).")
		}

		let decoded = try? JSONDecoder().decode(VexSignAPI.URLsResponse.self, from: data)
		let urls = (decoded?.urls ?? []).compactMap { URL(string: $0.url) }
		guard !urls.isEmpty else { throw PremiumError.message("Key validated but no repositories were returned.") }

		return urls
	}

	private func _activate(with urls: [URL]) async throws -> Int {
		VexSignAPI.registerPremiumSources(urls)

		let repositories = await RepositoryCatalogService.fetchRepositories(from: urls)
		guard !repositories.isEmpty else { throw PremiumError.empty }

		VexSignAPI.isPremium = true
		VexSignAPI.savePremiumURLs(urls)

		let repos = Dictionary(repositories.map { ($0.url, $0.data) }, uniquingKeysWith: { first, _ in first })

		await withCheckedContinuation { continuation in
			Storage.shared.addSources(repos: repos) { _ in
				continuation.resume()
			}
		}

		refresh()
		return repos.count
	}
}
