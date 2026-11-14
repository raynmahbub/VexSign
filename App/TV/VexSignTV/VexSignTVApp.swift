//
//  VexSignTVApp.swift
//  VexSignTV
//
//  Apple TV companion. It is a *mirror*, not a signer: the television has no
//  certificate, no storage for IPAs and no `installd`, so what it can genuinely
//  do is show what the iPhone is doing — certificate countdown, library, pending
//  updates — on a big screen, from the Web Manager the phone already runs.
//

import SwiftUI

@main
struct VexSignTVApp: App {
	@StateObject private var store = CompanionStore.shared

	var body: some Scene {
		WindowGroup {
			TVRootView()
				.environmentObject(store)
				.preferredColorScheme(.dark)
		}
	}
}

// MARK: - Root

struct TVRootView: View {
	@EnvironmentObject private var store: CompanionStore

	var body: some View {
		Group {
			if store.isConfigured {
				TVHomeView()
			} else {
				TVConnectView()
			}
		}
		.task {
			store.connectIfNeeded()
		}
	}
}
