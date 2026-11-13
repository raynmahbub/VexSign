//
//  HomeView+Actions.swift
//  VexSign
//
//  Import, drag-and-drop, URL download, and tab routing actions for HomeView.
//

import SwiftUI
import UniformTypeIdentifiers
import NimbleExtensions

extension HomeView {
    func openTab(_ tab: TabEnum) {
        // Re-surface any destination hidden in Settings before navigating to it.
        TabBarPreferences.shared.setHidden(tab, false)
        TabSelectionObserver.shared.selectedTab = tab
    }

    func browseForPackages(quickSign: Bool = false) {
        DocumentPicker.open([.ipa, .tipa], multiple: !quickSign, folder: .apps) { urls in
            guard !urls.isEmpty else { return }
            if quickSign {
                enqueuePackage(urls[0], quickSign: true)
            } else {
                urls.forEach { enqueuePackage($0) }
            }
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            let identifier = provider.registeredTypeIdentifiers.first { id in
                UTType(id)?.conforms(to: .fileURL) == true
            } ?? UTType.fileURL.identifier

            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let itemURL = item as? NSURL {
                    url = itemURL as URL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let path = item as? String {
                    url = URL(fileURLWithPath: path)
                } else {
                    url = nil
                }

                guard let url else { return }
                DispatchQueue.main.async {
                    guard ["ipa", "tipa"].contains(url.pathExtension.lowercased()) else {
                        Toast.error(.localized("Please drop an IPA or TIPA file."))
                        return
                    }
                    enqueuePackage(url)
                }
            }
        }
        return true
    }

    func enqueuePackage(_ url: URL, quickSign: Bool = false) {
        guard let stagedURL = stagePackage(url) else { return }

        if quickSign {
            // Quick Sign uses the same import pipeline as the Library, but keeps
            // the returned app so the signing sheet can open immediately.
            FR.handlePackageFile(stagedURL) { result in
                switch result {
                case .success(let app):
                    Task { @MainActor in
                        ImportDuplicateReview.resolve(app) { chosen, _ in
                            Toast.success(.localized("App ready to sign"), systemImage: "signature")
                            quickSignApp = AnyApp(base: chosen)
                        }
                    }
                case .failure(let error):
                    Toast.error(error.localizedDescription, duration: .long)
                }
            }
            return
        }

        _ = downloadManager.startArchive(
            from: stagedURL,
            id: "VexSignHomeImport_\(UUID().uuidString)",
            appName: stagedURL.deletingPathExtension().lastPathComponent,
            reviewDuplicates: true
        ) { error in
            if error is CancellationError { return }
            if let error {
                Toast.error(error.localizedDescription, duration: .long)
            }
        }
    }

    func stagePackage(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        let fileManager = FileManager.default
        let directory = fileManager.downloadStaging
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = FileManagerActions.uniqueURL(for: url.lastPathComponent, in: directory)
            try fileManager.copyItem(at: url, to: target)
            return target
        } catch {
            Toast.error(error.localizedDescription, duration: .long)
            return nil
        }
    }

    func startURLDownload() {
        let value = packageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            Toast.error(.localized("Enter a valid HTTP or HTTPS app URL."))
            return
        }

        let download = downloadManager.startDownload(
            from: url,
            id: "VexSignHomeURL_\(UUID().uuidString)",
            appName: url.deletingPathExtension().lastPathComponent
        )
        // Rejected requests return an untracked placeholder; the manager reports why.
        // An existing row can also be paused, so do not claim it has started.
        guard VexHomeDownloadFeedback.isTracked(download, in: downloadManager.downloads) else { return }
        Toast.info(.localized("Check Downloads for status."), systemImage: "arrow.down.circle")
        packageURL = ""
    }
}
