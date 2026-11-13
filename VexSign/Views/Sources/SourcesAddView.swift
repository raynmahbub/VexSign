//
//  SourcesAddView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 1.05.2025.
//

import SwiftUI
import NimbleViews
import AltSourceKit
import NimbleJSON
import OSLog
import UIKit.UIImpactFeedbackGenerator
import NimbleExtensions

// MARK: - View
struct SourcesAddView: View {
	@Environment(\.dismiss) var dismiss

	@State private var _filteredRecommendedSourcesData: [(url: URL, data: ASRepository)] = []
	func _refreshFilteredRecommendedSourcesData() {
		let filtered = recommendedSourcesData
			.filter { url, data in
				let id = data.id ?? url.absoluteString
				return !Storage.shared.sourceExists(id)
			}
			.sorted { lhs, rhs in
				let lhsName = lhs.data.name ?? ""
				let rhsName = rhs.data.name ?? ""
				return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
			}
		_filteredRecommendedSourcesData = filtered
	}

	@State var recommendedSourcesData: [(url: URL, data: ASRepository)] = []
	let recommendedSources: [URL] = [
		"https://raw.githubusercontent.com/raynmahbub/VexSign/refs/heads/main/app-repo.json",
		"https://raw.githubusercontent.com/Aidoku/Aidoku/altstore/apps.json",
		"https://github.com/chachillie/Flycast-iOS/raw/main/flycast-ios.json",
		"https://xitrix.github.io/iTorrent/AltStore.json",
		"https://altstore.oatmealdome.me/",
		"https://raw.githubusercontent.com/LiveContainer/LiveContainer/refs/heads/main/apps.json",
		"https://pokemmo.com/altstore",
		"https://provenance-emu.com/apps.json",
		"https://community-apps.sidestore.io/sidecommunity.json",
		"https://raw.githubusercontent.com/Nyasami/Ksign/refs/heads/main/repo.json",
		"https://alt.getutm.app",
		"https://raw.githubusercontent.com/paigely/Navic/refs/heads/master/app-repo.json",
		"https://stikdebug.xyz/index.json",
		"https://apps.manicemu.site/altstore",
		"https://alt.crystall1ne.dev",
		"https://mikevillarroel.github.io/mikebuilds-source/originals.json"
	].compactMap { URL(string: $0) }

	// MARK: - Vex Repos Collection
	@State var vexRepos: [URL] = []
	@State var vexReposCount: Int = 0
	@State var vexReposFetchError: String?

	// MARK: - Premium VexSign API
	@State var _showPremiumKeyPrompt = false
	@State var _premiumAPIKey = ""
	@State var _isValidatingAPIKey = false
	@State var _showPremiumError = false
	@State var _premiumErrorMessage = ""
	@State private var _showResetConfirmation = false
	@State private var _showRestorePrompt = false
	@ObservedObject var _premium = PremiumManager.shared

	@State private var _isImporting = false
	@State var _isAddingVexRepos = false
	@State private var _isSavingSource = false
	@State private var _sourceURL = ""
	@State private var _showVexErrorAlert = false

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Add Source"), displayMode: .inline) {
			formContent
				.toolbar { toolbarContent }
				.animation(.default, value: _filteredRecommendedSourcesData.map { $0.data.id ?? "" })
				.alert("Failed to Load Vex Repos", isPresented: $_showVexErrorAlert) {
					Button("OK", role: .cancel) { }
					Button("Retry") {
						Task {
							await _fetchVexReposList()
						}
					}
				} message: {
					Text(vexReposFetchError ?? "An unknown error occurred")
				}
				.alert("Premium Access", isPresented: $_showPremiumKeyPrompt) {
					TextField("VEX-XXXX-XXXX-XXXX", text: $_premiumAPIKey)
						.textInputAutocapitalization(.characters)
						.autocorrectionDisabled()
						.font(.system(.body, design: .monospaced))

					Button("Redeem Key") {
						_validatePremiumAPIKey()
					}
					.disabled(_premiumAPIKey.isEmpty || _isValidatingAPIKey)

					Button("Cancel", role: .cancel) {
						_premiumAPIKey = ""
					}
				} message: {
					Text("Enter your VexSign API key to unlock premium repositories.")
				}
				.alert("Error", isPresented: $_showPremiumError) {
					Button("Contact \(VexSignAPI.telegramUsername)") {
						VexSignAPI.openTelegram()
					}
					Button("OK", role: .cancel) { }
				} message: {
					Text(_premiumErrorMessage)
				}
				.alert("Reset Premium?", isPresented: $_showResetConfirmation) {
					Button("Reset", role: .destructive) {
						_resetPremium()
					}
					Button("Cancel", role: .cancel) { }
				} message: {
					Text("This will remove all VexSign premium repositories and clear your activation. You will need a new key to reactivate.")
				}
				.alert("Premium Found", isPresented: $_showRestorePrompt) {
					Button("Restore") {
						_restorePremium()
					}
					Button("No Thanks", role: .destructive) {
						VexSignAPI.clearPremiumIdentity()
					}
				} message: {
					Text("A previous VexSign premium activation was found on this device. Would you like to restore your premium repositories?")
				}
				.task {
					VexSignAPI.migrateIfNeeded()
					_premium.refresh()
					await _fetchRecommendedRepositories()
					await _fetchVexReposList()
				}
		}
	}

	@ViewBuilder
	var formContent: some View {
		Form {
			sourceURLSection
			importExportSection
			premiumVexSignSection
			vexReposSection
			featuredSection
		}
		.dismissableKeyboard()
	}

	@ViewBuilder
	var sourceURLSection: some View {
		NBSection(.localized("Source URL")) {
			TextField(.localized("Enter Source URL"), text: $_sourceURL)
				.keyboardType(.URL)
				.textInputAutocapitalization(.never)
		} footer: {
			Text(.localized("Supports AltStore-compatible sources and GitHub repositories with one .ipa asset in the latest release."))
			Text(.localized("GitHub release sources do not include bundle IDs, so automatic update matching may not be available."))
			Text(verbatim: "[\(String.localized("Learn more about how to setup a repository..."))](https://faq.altstore.io/developers/make-a-source)")
		}
	}

	@ViewBuilder
	var importExportSection: some View {
		Section {
			Button(.localized("Import"), systemImage: "square.and.arrow.down") {
				_isImporting = true
				_fetchImportedRepositories(UIPasteboard.general.string) { success, count in
					_isImporting = false
					if success {
						Toast.success("Successfully imported \(count) source\(count == 1 ? "" : "s")")
					} else {
						Toast.error("No valid sources found in clipboard", duration: .sticky)
					}
				}
			}

			Button(.localized("Export"), systemImage: "doc.on.doc") {
				let sources = Storage.shared.getSources()
				if sources.isEmpty {
					Toast.error("No sources to export", duration: .sticky)
				} else {
					UIPasteboard.general.string = sources.compactMap {
						$0.sourceURL?.absoluteString
					}.joined(separator: "\n")
					Toast.success("Successfully exported \(sources.count) source\(sources.count == 1 ? "" : "s") to clipboard")
				}
			}
		} footer: {
			Text(.localized("Supports importing from KravaSign/MapleSign and ESign."))
		}
	}

	@ViewBuilder
	var premiumVexSignSection: some View {
		Section {
			if _premium.isActive {
				NavigationLink {
					PremiumSettingsView()
				} label: {
					HStack {
						Image(systemName: "crown.fill")
							.foregroundColor(.yellow)
						VStack(alignment: .leading, spacing: 2) {
							Text("Premium VexSign")
								.font(.headline)
								.foregroundColor(.primary)
							Text("Premium activated")
								.font(.caption)
								.foregroundColor(.green)
						}
						Spacer()
						Image(systemName: "checkmark.seal.fill")
							.foregroundColor(.green)
					}
				}
				.swipeActions(edge: .trailing, allowsFullSwipe: false) {
					Button("Reset", role: .destructive) {
						_showResetConfirmation = true
					}
				}
			} else {
				Button(action: {
					if VexSignAPI.hasStoredPremiumButNotLocal {
						_showRestorePrompt = true
					} else {
						_premiumAPIKey = ""
						_showPremiumKeyPrompt = true
					}
				}) {
					HStack {
						Image(systemName: "crown.fill")
							.foregroundColor(.yellow)
						VStack(alignment: .leading, spacing: 2) {
							Text("Premium VexSign")
								.font(.headline)
								.foregroundColor(.primary)
							Text("Redeem API key for premium repos")
								.font(.caption)
								.foregroundColor(.secondary)
						}
						Spacer()
						if _isValidatingAPIKey {
							ProgressView()
								.scaleEffect(0.8)
						} else {
							Image(systemName: "key.fill")
								.foregroundColor(.secondary)
								.font(.caption)
						}
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(PlainButtonStyle())
				.disabled(_isValidatingAPIKey)
			}

			Button(action: {
				VexSignAPI.openTelegram()
			}) {
				HStack {
					Image(systemName: "paperplane.fill")
						.foregroundColor(.blue)
					VStack(alignment: .leading, spacing: 2) {
						Text("Get a Key")
							.font(.headline)
							.foregroundColor(.primary)
						Text("\(VexSignAPI.contactSuffix)")
							.font(.caption)
							.foregroundColor(.secondary)
					}
					Spacer()
					Image(systemName: "arrow.up.right")
						.foregroundColor(.secondary)
						.font(.caption)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(PlainButtonStyle())
		} footer: {
			if _premium.isActive {
				Text("Tap to manage premium options, or swipe left to reset.")
			} else {
				Text("API keys are single-use.")
			}
		}
	}

	@ViewBuilder
	var vexReposSection: some View {
		Section {
			Button(action: {
				if vexRepos.isEmpty {
					Task {
						await _fetchVexReposList()
						if !vexRepos.isEmpty {
							_isAddingVexRepos = true
							_addVexRepos()
						}
					}
				} else {
					_isAddingVexRepos = true
					_addVexRepos()
				}
			}) {
				HStack {
					Image(systemName: "bolt.fill")
						.foregroundColor(.orange)
					VStack(alignment: .leading, spacing: 2) {
						Text("Vex Repos")
							.font(.headline)
							.foregroundColor(.primary)
						if vexReposCount > 0 {
							Text("Add \(vexReposCount) Vex crafted repositories")
								.font(.caption)
								.foregroundColor(.secondary)
						} else if vexReposFetchError != nil {
							Text("Tap to retry loading repositories")
								.font(.caption)
								.foregroundColor(.red)
						} else {
							Text("Loading repositories...")
								.font(.caption)
								.foregroundColor(.secondary)
						}
					}
					Spacer()
					if _isAddingVexRepos || (vexReposCount == 0 && vexReposFetchError == nil) {
						ProgressView()
							.scaleEffect(0.8)
					} else if vexReposFetchError != nil {
						Image(systemName: "exclamationmark.triangle")
							.foregroundColor(.red)
							.font(.caption)
					} else {
						Image(systemName: "chevron.right")
							.foregroundColor(.secondary)
							.font(.caption)
					}
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(PlainButtonStyle())
			.disabled(_premium.isActive || _isAddingVexRepos || (vexReposCount == 0 && vexReposFetchError == nil))
			.opacity(_premium.isActive ? 0.4 : 1.0)
		} footer: {
			if _premium.isActive {
				Text("Already included in your premium repositories.")
			} else if let error = vexReposFetchError {
				Text(error)
					.foregroundColor(.red)
			} else {
				Text("Add a collection of popular repositories crafted by Vex.")
			}
		}
	}

	@ViewBuilder
	var featuredSection: some View {
		if !_filteredRecommendedSourcesData.isEmpty {
			NBSection(.localized("Featured")) {
				ForEach(_filteredRecommendedSourcesData, id: \.url) { url, source in
					HStack(spacing: 2) {
						FRIconCellView(
							title: source.name ?? .localized("Unknown"),
							subtitle: url.absoluteString,
							iconUrl: source.currentIconURL
						)
						Button {
							Storage.shared.addSource(url, repository: source) { error in
								_refreshFilteredRecommendedSourcesData()
								if let error = error {
									Toast.error(error.localizedDescription, duration: .sticky)
								} else {
									let sourceName = source.name ?? "Repository"
									Toast.success("Successfully added \(sourceName)")
								}
							}
						} label: {
							NBButton(.localized("Add"), systemImage: "arrow.down", style: .text)
						}
					}
				}
			} footer: {
				Text(.localized("Open an [issue](https://github.com/raynmahbub/VexSign/issues) on GitHub if you want your source to be featured."))
			}
		}
	}

	@ToolbarContentBuilder
	var toolbarContent: some ToolbarContent {
		NBToolbarButton(role: .cancel)

		if !_isImporting && !_isAddingVexRepos && !_isSavingSource {
			NBToolbarButton(
				.localized("Save"),
				style: .text,
				placement: .confirmationAction
			) {
				if _sourceURL.isEmpty {
					dismiss()
					return
				}

				_isSavingSource = true
				FR.handleSource(_sourceURL, showAlerts: false) { result in
					_isSavingSource = false
					switch result {
					case .success(let sourceName):
						Toast.success("Successfully added \(sourceName)")
						dismiss()
					case .failure(let error):
						Toast.error(error.localizedDescription, duration: .sticky)
					}
				}
			}
		} else {
			ToolbarItem(placement: .confirmationAction) {
				ProgressView()
			}
		}
	}
}
