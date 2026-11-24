//
//  VexSignVisionApp.swift
//  VexSignVision
//
//  Apple Vision Pro companion. Same rule as Apple TV: this is a mirror of the
//  iPhone, not a second signer — visionOS cannot install IPAs, so the app shows
//  certificate health, library and update state in a spatial window and lets you
//  trigger the phone's own refresh/check/automation passes from the couch.
//

import SwiftUI

@main
struct VexSignVisionApp: App {
	@StateObject private var store = CompanionStore.shared

	var body: some Scene {
		WindowGroup {
			VisionRootView()
				.environmentObject(store)
				.frame(minWidth: 720, minHeight: 520)
		}
		.windowStyle(.automatic)
	}
}

// MARK: - Root

struct VisionRootView: View {
	@EnvironmentObject private var store: CompanionStore
	@State private var _showConnection = false

	var body: some View {
		VisionHomeView()
			.task {
				store.connectIfNeeded()
			}
			.sheet(isPresented: $_showConnection) {
				VisionConnectView()
					.frame(width: 520)
			}
			.ornament(attachmentAnchor: .scene(.bottomTrailing)) {
				HStack(spacing: 12) {
					if store.isRefreshing {
						ProgressView()
					}

					Button {
						Task { await store.refresh() }
					} label: {
						Label("Refresh", systemImage: "arrow.clockwise")
					}

					Button {
						_showConnection = true
					} label: {
						Label("Connection", systemImage: "wifi")
					}
				}
				.glassBackgroundEffect()
			}
	}
}
