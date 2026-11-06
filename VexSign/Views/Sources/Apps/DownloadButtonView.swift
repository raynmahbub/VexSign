//
//  DownloadButtonView.swift
//  VexSign
//
//  Created by samsam on 7/25/25.
//
import SwiftUI
import Combine
import AltSourceKit
import NimbleViews
import NimbleExtensions
import CoreData

// MARK: - Tab Selection Observer
class TabSelectionObserver: ObservableObject {
	static let shared = TabSelectionObserver()
	@Published var selectedTab: TabEnum = TabBarPreferences.shared.resolvedLaunchTab
    @Published var librarySection: LibraryWorkspaceSection = .apps
    @Published var activitySection: ActivityWorkspaceSection = .downloads
    @Published var ipaExplorerRequested = false
	@Published var highlightedAppUUID: String?
	@Published var sourcesRetapped: Bool = false
    @Published var searchRequest: WorkspaceSearchRequest?
	
    func search(_ query: String, in tab: TabEnum) {
        guard [.library, .appStore, .settings].contains(tab) else { return }
        searchRequest = WorkspaceSearchRequest(tab: tab, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        if tab == .library { librarySection = .apps }
        selectedTab = tab
    }

    /// Route old standalone Files/Logs links into the merged workspaces.
    func navigate(to route: WorkspaceRoute) {
        if let section = route.librarySection { librarySection = section }
        if let section = route.activitySection { activitySection = section }
        selectedTab = route.tab
    }

    func requestIPAExplorer() {
        navigate(to: .apps)
        // Persist the intent until Library mounts (it may currently show Files).
        ipaExplorerRequested = true
    }

	private var highlightTimer: Timer?
	
	func navigateToLibraryWithHighlight(uuid: String) {
        librarySection = .apps
		highlightedAppUUID = uuid
		DispatchQueue.main.async {
			self.selectedTab = .library
		}
		
		highlightTimer?.invalidate()
		highlightTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
			DispatchQueue.main.async {
				withAnimation(.easeOut(duration: 0.3)) {
					self.highlightedAppUUID = nil
				}
			}
		}
	}
}

struct DownloadButtonView: View {
	let app: ASRepository.App
	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var privacyManager = AppLockManager.shared
	@State private var downloadProgress: Double = 0
	@State private var downloadPhase: DownloadPhase = .queued
	@State private var cancellable: AnyCancellable?

	@State private var installedApp: InstalledAppInfo?
	@State private var isCheckingInstalled = true
	@State private var hasAppeared = false

	private let tabSelection = TabSelectionObserver.shared
	
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: []
	) private var signedApps: FetchedResults<Signed>
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: []
	) private var importedApps: FetchedResults<Imported>
	
	struct InstalledAppInfo {
		let uuid: String
		let name: String
		let version: String?
		let type: AppType
		let sourceApp: ASRepository.App

		enum AppType {
			case signed
			case imported
		}

		var hasUpdate: Bool {
			guard let currentVersion = version else { return false }
			guard let sourceVersion = sourceApp.currentVersion else { return false }

			return isNewerVersion(sourceVersion, than: currentVersion)
		}

		var isDowngrade: Bool {
			guard let currentVersion = version else { return false }
			guard let sourceVersion = sourceApp.currentVersion else { return false }

			return isNewerVersion(currentVersion, than: sourceVersion)
		}

		private func isNewerVersion(_ new: String, than old: String) -> Bool {
			let newComponents = new.split(separator: ".").compactMap { Int($0) }
			let oldComponents = old.split(separator: ".").compactMap { Int($0) }

			let maxCount = max(newComponents.count, oldComponents.count)

			for i in 0..<maxCount {
				let newValue = i < newComponents.count ? newComponents[i] : 0
				let oldValue = i < oldComponents.count ? oldComponents[i] : 0

				if newValue > oldValue {
					return true
				} else if newValue < oldValue {
					return false
				}
			}

			return false
		}
	}

	private var _phaseSymbol: String {
		switch downloadPhase {
		case .importing: return "archivebox"
		case .signing: return "signature"
		default: return "square.fill"
		}
	}

	var body: some View {
		ZStack {
			if let currentDownload = downloadManager.getDownload(by: app.currentUniqueId) {
				ZStack {
					DownloadPhaseRing(phase: downloadPhase, progress: downloadProgress, size: 31, lineWidth: 2.3)

					Image(systemName: _phaseSymbol)
						.foregroundStyle(downloadPhase.tint)
						.font(.footnote).bold()
				}
				.onTapGesture {
					if currentDownload.canCancel {
						downloadManager.cancelDownload(currentDownload)
					}
				}
				.transition(.scale.combined(with: .opacity))
			} else if let installedApp = installedApp {
				HStack(spacing: 8) {
					if installedApp.hasUpdate {
						Button {
							NBHaptic.tap()
							if let url = app.currentDownloadUrl {
                                _ = downloadManager.startDownload(from: url, id: app.currentUniqueId, appName: app.currentName, appDescription: app.localizedDescription, integrity: app.downloadIntegrityExpectation)
							}
						} label: {
							Text(.localized("Update"))
								.lineLimit(1)
								.font(.headline.bold())
								.foregroundStyle(.white)
								.padding(.horizontal, 20)
								.padding(.vertical, 6)
								.background(Color.accentColor)
								.clipShape(Capsule())
						}
						.buttonStyle(.borderless)
						.transition(.scale.combined(with: .opacity))
					} else if installedApp.isDowngrade {
						Button {
							NBHaptic.tap()
							if let url = app.currentDownloadUrl {
								_ = downloadManager.startDownload(from: url, id: app.currentUniqueId, appName: app.currentName, appDescription: app.localizedDescription, integrity: app.downloadIntegrityExpectation)
							}
						} label: {
							HStack(spacing: 4) {
								Image(systemName: "clock.arrow.circlepath")
									.font(.headline.bold())
								Text("Get")
									.lineLimit(1)
									.font(.headline.bold())
							}
							.foregroundStyle(.secondary)
							.padding(.horizontal, 20)
							.padding(.vertical, 6)
							.background(Color(uiColor: .quaternarySystemFill))
							.clipShape(Capsule())
						}
						.buttonStyle(.borderless)
						.transition(.scale.combined(with: .opacity))
					} else {
						Button {
							tabSelection.navigateToLibraryWithHighlight(uuid: installedApp.uuid)
						} label: {
							Text(.localized(installedApp.type == .imported ? "Imported" : "Signed"))
								.lineLimit(1)
								.font(.headline.bold())
								.foregroundStyle(.secondary)
								.padding(.horizontal, 16)
								.padding(.vertical, 6)
								.background(Color(uiColor: .quaternarySystemFill))
								.clipShape(Capsule())
						}
						.buttonStyle(.borderless)
						.transition(.scale.combined(with: .opacity))
					}
					
					Menu {
						if installedApp.hasUpdate || installedApp.isDowngrade || !installedApp.hasUpdate && !installedApp.isDowngrade {
							Button {
								tabSelection.navigateToLibraryWithHighlight(uuid: installedApp.uuid)
							} label: {
								Label(.localized("View in Library"), systemImage: "square.grid.2x2")
							}
						}

						Button {
							NBHaptic.tap()
							if let url = app.currentDownloadUrl {
                                _ = downloadManager.startDownload(from: url, id: app.currentUniqueId, appName: app.currentName, appDescription: app.localizedDescription, integrity: app.downloadIntegrityExpectation)
							}
						} label: {
							Label(.localized("Download Again"), systemImage: "arrow.down.circle")
						}
					} label: {
						Image(systemName: "ellipsis.circle")
							.font(.body.bold())
							.foregroundStyle(Color.accentColor)
							.frame(width: 31, height: 31)
							.background(Color(uiColor: .quaternarySystemFill))
							.clipShape(Circle())
					}
					.buttonStyle(.borderless)
				}
			} else if !isCheckingInstalled {
				Menu {
					Button {
						NBHaptic.tap()
						if let url = app.currentDownloadUrl {
							_ = downloadManager.startDownload(from: url, id: app.currentUniqueId, appName: app.currentName, appDescription: app.localizedDescription, integrity: app.downloadIntegrityExpectation)
						}
					} label: {
						Label(.localized("Download"), systemImage: "arrow.down.circle")
					}

					Button {
						NBHaptic.tap()
						// Flip the store-like pipeline on, then download: import → sign → install → clean.
						if !CleanupManager.shared.isOneTapInstall {
							CleanupManager.shared.setOneTapInstall(true)
						}
						if let url = app.currentDownloadUrl {
							_ = downloadManager.startDownload(from: url, id: app.currentUniqueId, appName: app.currentName, appDescription: app.localizedDescription, integrity: app.downloadIntegrityExpectation)
						}
					} label: {
						Label(.localized("Download, Sign & Install"), systemImage: "wand.and.stars")
					}
				} label: {
					HStack(spacing: 4) {
						Image(systemName: "arrow.down.circle")
							.font(.headline.bold())
						Text(.localized("Get"))
							.lineLimit(1)
							.font(.headline.bold())
					}
					.foregroundStyle(Color.accentColor)
					.padding(.horizontal, 20)
					.padding(.vertical, 6)
					.background(Color(uiColor: .quaternarySystemFill))
					.clipShape(Capsule())
				}
				.buttonStyle(.borderless)
				.transition(.scale.combined(with: .opacity))
			}
		}
		.onAppear {
			setupObserver()
			checkIfInstalled()
			// Delay setting hasAppeared to prevent initial animation
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
				hasAppeared = true
			}
		}
		.onDisappear { 
			cancellable?.cancel() 
		}
		.onChange(of: downloadManager.downloads.description) { _ in
			setupObserver()
		}
		.onChange(of: signedApps.count) { _ in
			checkIfInstalled()
		}
		.onChange(of: importedApps.count) { _ in
			checkIfInstalled()
		}
		.animation(hasAppeared ? .easeInOut(duration: 0.25) : nil, value: downloadManager.getDownload(by: app.currentUniqueId) != nil)
		.animation(hasAppeared ? .easeInOut(duration: 0.25) : nil, value: installedApp != nil)
	}
	
	private func setupObserver() {
		cancellable?.cancel()
		guard let download = downloadManager.getDownload(by: app.currentUniqueId) else {
			downloadProgress = 0
			return
		}
		syncProgress(from: download)
		let publisher = Publishers.CombineLatest3(
			download.$progress,
			download.$unpackageProgress,
			download.$isPaused
		)
		cancellable = publisher.sink { _, _, _ in
			syncProgress(from: download)
		}
	}
	
	private func syncProgress(from download: Download) {
		downloadProgress = download.phaseProgress
		downloadPhase = download.phase
	}

	private func checkIfInstalled() {
        isCheckingInstalled = true

        let appBundleId = app.id ?? ""
        let appNameLower = app.currentName.lowercased()

        func compareVersions(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let l = lhs, let r = rhs else { return false }
            let lParts = l.split(separator: ".").compactMap { Int($0) }
            let rParts = r.split(separator: ".").compactMap { Int($0) }
            for i in 0..<max(lParts.count, rParts.count) {
                let lv = i < lParts.count ? lParts[i] : 0
                let rv = i < rParts.count ? rParts[i] : 0
                if lv != rv { return lv > rv }
            }
            return false
        }

        func identifiersMatch(_ sourceId: String, _ storedId: String?, _ originalId: String?) -> Bool {
            if let originalId = originalId, sourceId == originalId { return true }
            if let storedId = storedId, sourceId == storedId { return true }
            return false
        }

        var candidates: [(uuid: String, name: String, version: String?, type: InstalledAppInfo.AppType)] = []

        for s in signedApps {
            if privacyManager.isStrictlyHidden(s.uuid ?? "") { continue }
            let identifierMatch = !appBundleId.isEmpty &&
                identifiersMatch(appBundleId, s.identifier, s.originalIdentifier)
            let nameMatch = (s.name ?? "").lowercased() == appNameLower

            if identifierMatch || nameMatch {
                candidates.append((s.uuid ?? "", s.name ?? "", s.version, .signed))
            }
        }

        for i in importedApps {
            if privacyManager.isStrictlyHidden(i.uuid ?? "") { continue }
            let identifierMatch = !appBundleId.isEmpty &&
                identifiersMatch(appBundleId, i.identifier, i.originalIdentifier)
            let nameMatch = (i.name ?? "").lowercased() == appNameLower

            if identifierMatch || nameMatch {
                candidates.append((i.uuid ?? "", i.name ?? "", i.version, .imported))
            }
        }

        if let best = candidates.max(by: { !compareVersions($0.version, $1.version) }) {
            installedApp = InstalledAppInfo(
                uuid: best.uuid,
                name: best.name,
                version: best.version,
                type: best.type,
                sourceApp: app
            )
        } else {
            installedApp = nil
        }

        isCheckingInstalled = false
    }
}
