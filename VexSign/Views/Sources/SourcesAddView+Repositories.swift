//
//  SourcesAddView+Repositories.swift
//  VexSign
//

import SwiftUI
import NimbleViews
import AltSourceKit
import OSLog
import UIKit.UIImpactFeedbackGenerator
import NimbleExtensions

extension SourcesAddView {
	// MARK: - Fetch Vex Repos List
	func _fetchVexReposList() async {
		await MainActor.run {
			vexReposFetchError = nil
		}

		do {
			var request = URLRequest(url: VexSignAPI.reposListURL)
			#if canImport(AltSourceKit)
			// The repos catalog may be a premium (authenticated) endpoint.
			if !EsignSourceKey.customApiKey.isEmpty {
				request.setValue(EsignSourceKey.customApiKey, forHTTPHeaderField: "X-API-Key")
			}
			#endif

			// Same: a catalog that never answers must surface as an error, not an endless spinner.
			request.timeoutInterval = 20
			let (data, response) = try await URLSession.shared.data(for: request)

			guard let httpResponse = response as? HTTPURLResponse,
				httpResponse.statusCode == 200 else {
				await MainActor.run {
					vexReposFetchError = "Failed to fetch repository list. Server returned an error."
					Logger.misc.error("Failed to fetch Vex repos: Invalid response")
				}
				return
			}

			let raw = try JSONSerialization.jsonObject(with: data, options: [])

			guard let strings = raw as? [String] else {
				await MainActor.run {
					vexReposFetchError = "Unexpected JSON format in repos.json"
				}
				return
			}

			let urls = strings.compactMap { URL(string: $0) }

			await MainActor.run {
				vexRepos = urls
				vexReposCount = urls.count
				vexReposFetchError = nil
				Logger.misc.info("Successfully fetched \(urls.count) Vex repos")
			}
		} catch {
			await MainActor.run {
				if (error as NSError).code == NSURLErrorNotConnectedToInternet ||
					(error as NSError).code == NSURLErrorTimedOut ||
					(error as NSError).code == NSURLErrorNetworkConnectionLost {
					vexReposFetchError = "No internet connection. Please check your network and try again."
				} else {
					vexReposFetchError = "Failed to load repositories: \(error.localizedDescription)"
				}
				vexReposCount = 0
				Logger.misc.error("Failed to fetch Vex repos: \(error.localizedDescription)")
			}
		}
	}

	// MARK: - Vex Repos Handler
	func _addVexRepos() {
		guard !vexRepos.isEmpty else {
			_isAddingVexRepos = false
			Toast.error("No Vex repositories available", duration: .sticky)
			return
		}

		Task {
			let fetched = await RepositoryCatalogService.fetchRepositories(from: vexRepos)
			let dict = Dictionary(fetched, uniquingKeysWith: { first, _ in first })

			await MainActor.run {
				if dict.isEmpty {
					_isAddingVexRepos = false
					Toast.error("Failed to fetch repository data. Please check your connection and try again.", duration: .sticky)
				} else {
					Storage.shared.addSources(repos: dict) { _ in
						Toast.success("Successfully added \(dict.count) Vex repositories")
						_isAddingVexRepos = false
						_refreshFilteredRecommendedSourcesData()
						dismiss()
					}
				}
			}
		}
	}

	func _fetchRecommendedRepositories() async {
		let fetched = await RepositoryCatalogService.fetchRepositories(from: recommendedSources)
		await MainActor.run {
			recommendedSourcesData = fetched
			_refreshFilteredRecommendedSourcesData()
		}
	}

	func _fetchImportedRepositories(
		_ code: String?,
		competion: @escaping (Bool, Int) -> Void
	) {
		guard let code else {
			competion(false, 0)
			return
		}

		let handler = ASDeobfuscator(with: code)
		let repoUrls = handler.decode().compactMap { URL(string: $0) }
		guard !repoUrls.isEmpty else {
			competion(false, 0)
			return
		}

		Task {
			let fetched = await RepositoryCatalogService.fetchRepositories(from: repoUrls)

			let dict = Dictionary(fetched, uniquingKeysWith: { first, _ in first })

			await MainActor.run {
				if dict.isEmpty {
					competion(false, 0)
				} else {
					Storage.shared.addSources(repos: dict) { _ in
						competion(true, dict.count)
					}
				}
			}
		}
	}

	// MARK: - Premium VexSign API

	func _validatePremiumAPIKey() {
		let apiKey = _premiumAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

		guard apiKey.hasPrefix("VEX-"), apiKey.count >= 16 else {
			_premiumErrorMessage = VexSignAPI.errorMessage("Invalid key format. Keys should be in format: VEX-XXXX-XXXX-XXXX")
			_showPremiumError = true
			return
		}

		_showPremiumKeyPrompt = false

		_runPremiumTask {
			try await PremiumManager.shared.redeem(key: apiKey)
		} onSuccess: { count in
			// Persist the redeemed key so it survives relaunches and is attached to
			// every subsequent repository fetch/decrypt request automatically.
			VexSignAPI.premiumAPIKey = apiKey
			#if canImport(AltSourceKit)
			EsignSourceKey.customApiKey = apiKey
			#endif
			Toast.success(.localized("Added %lld premium repositories", arguments: count))
			_refreshFilteredRecommendedSourcesData()
			dismiss()
		}
	}

	func _restorePremium() {
		guard VexSignAPI.getSavedPremiumURLs() != nil || VexSignAPI.isPremium else {
			VexSignAPI.clearPremiumIdentity()
			_premiumAPIKey = ""
			_showPremiumKeyPrompt = true
			return
		}

		_runPremiumTask {
			try await PremiumManager.shared.restore()
		} onSuccess: { count in
			Toast.success(.localized("Restored %lld premium repositories", arguments: count))
			_refreshFilteredRecommendedSourcesData()
		}
	}

	func _resetPremium() {
		PremiumManager.shared.reset()
		Toast.success(.localized("Premium activation has been reset"))
		_refreshFilteredRecommendedSourcesData()
	}

	private func _runPremiumTask(
		_ work: @escaping () async throws -> Int,
		onSuccess: @escaping (Int) -> Void
	) {
		_isValidatingAPIKey = true

		Task { @MainActor in
			defer {
				_isValidatingAPIKey = false
				_premiumAPIKey = ""
			}

			do {
				onSuccess(try await work())
			} catch {
				_premiumErrorMessage = VexSignAPI.errorMessage(error.localizedDescription)
				_showPremiumError = true
				UINotificationFeedbackGenerator().notificationOccurred(.error)
			}
		}
	}
}
