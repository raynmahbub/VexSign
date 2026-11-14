//
//  VexSignWatchApp.swift
//  VexSignWatch
//
//  Apple Watch companion. It shows what the iPhone publishes over
//  WatchConnectivity and can trigger four of the phone's own passes. It cannot
//  sign or install anything — a watch has no certificate, no IPA storage and no
//  `installd`, and this app does not pretend otherwise.
//

import SwiftUI
import WatchKit

@main
struct VexSignWatchApp: App {
	@WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
	@StateObject private var store = WatchSessionStore.shared

	var body: some Scene {
		WindowGroup {
			WatchRootView()
				.environmentObject(store)
		}
	}
}

// MARK: - Delegate

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
	func applicationDidFinishLaunching() {
		WatchSessionStore.shared.activate()
	}

	/// A complication tap or a scheduled background refresh is a good moment to
	/// ask the phone for fresh numbers.
	func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
		for task in backgroundTasks {
			if let snapshotTask = task as? WKSnapshotRefreshBackgroundTask {
				snapshotTask.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: Date().addingTimeInterval(60), userInfo: nil)
			} else if let connectivityTask = task as? WKApplicationRefreshBackgroundTask {
				connectivityTask.setTaskCompletedWithSnapshot(false)
			} else {
				task.setTaskCompletedWithSnapshot(false)
			}
		}
	}
}

// MARK: - Root

struct WatchRootView: View {
	@EnvironmentObject private var store: WatchSessionStore

	var body: some View {
		NavigationStack {
			WatchHomeView()
		}
		.onAppear {
			store.activate()
		}
	}
}
