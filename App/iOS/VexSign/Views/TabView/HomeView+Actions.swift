//
//  HomeView+Actions.swift
//  VexSign
//
//  Import, drag-and-drop, URL download, and tab routing actions for HomeView,
//  delegating operational work to `HomeActionCoordinator`.
//

import SwiftUI
import UniformTypeIdentifiers
import NimbleExtensions

extension HomeView {
    private var actionCoordinator: HomeActionCoordinator {
        (appContainer ?? AppContainer.live()).makeHomeActionCoordinator { chosen in
            quickSignApp = chosen
        }
    }

    func openTab(_ tab: TabEnum) {
        actionCoordinator.openTab(tab)
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
        actionCoordinator.handleDrop(providers)
    }

    func enqueuePackage(_ url: URL, quickSign: Bool = false) {
        actionCoordinator.enqueuePackage(url, quickSign: quickSign)
    }

    func stagePackage(_ url: URL) -> URL? {
        actionCoordinator.stagePackage(url)
    }

    func startURLDownload() {
        if actionCoordinator.startURLDownload(rawURL: packageURL) {
            packageURL = ""
        }
    }
}
