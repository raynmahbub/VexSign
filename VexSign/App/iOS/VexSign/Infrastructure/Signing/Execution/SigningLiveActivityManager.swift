//
//  SigningLiveActivityManager.swift
//  VexSign
//
//  Manages the Live Activity for single-app and batch signing operations.
//

import Foundation
import ActivityKit
import NimbleExtensions

enum LiveActivityPreferences {
	static let enabledKey = "VexSign.liveActivitiesEnabled"
	static let legacyDynamicIslandKey = "VexSign.dynamicIslandEnabled"

	static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
		if defaults.object(forKey: enabledKey) == nil {
			return true
		}
		return defaults.bool(forKey: enabledKey)
	}

	@available(iOS 16.2, *)
	static func canStartActivity(defaults: UserDefaults = .standard) -> Bool {
		isEnabled(defaults: defaults) && ActivityAuthorizationInfo().areActivitiesEnabled
	}
}

@MainActor
final class SigningLiveActivityManager {
	static let shared = SigningLiveActivityManager()

	private var _activity: Any? // Activity<SigningActivityAttributes> on iOS 16.2+

	private init() {}

	func start(appName: String, currentApp: Int = 1, totalApps: Int = 1) {
		guard #available(iOS 16.2, *) else { return }
		guard LiveActivityPreferences.canStartActivity() else { return }

		// End any stale signing activity
		endAll()

		let attributes = SigningActivityAttributes(startTime: Date())
		let state = SigningActivityAttributes.ContentState(
			appName: appName,
			progress: 0.05,
			status: .localized("Signing…"),
			currentApp: currentApp,
			totalApps: totalApps,
			isCompleted: false
		)
		let content = ActivityContent(state: state, staleDate: nil)

		do {
			let activity = try Activity.request(attributes: attributes, content: content)
			_activity = activity
		} catch {
			// Live Activities might be disabled by user or system
		}
	}

	func update(progress: Double, status: String? = nil, appName: String? = nil, currentApp: Int? = nil, totalApps: Int? = nil) {
		guard #available(iOS 16.2, *) else { return }
		guard let activity = _activity as? Activity<SigningActivityAttributes> else { return }

		var state = activity.content.state
		if let appName { state.appName = appName }
		if let status { state.status = status }
		if let currentApp { state.currentApp = currentApp }
		if let totalApps { state.totalApps = totalApps }
		state.progress = min(1.0, max(0.0, progress))

		Task {
			await activity.update(ActivityContent(state: state, staleDate: nil))
		}
	}

	func complete(appName: String? = nil) {
		guard #available(iOS 16.2, *) else { return }
		guard let activity = _activity as? Activity<SigningActivityAttributes> else { return }

		var state = activity.content.state
		if let appName { state.appName = appName }
		state.progress = 1.0
		state.status = .localized("Done")
		state.isCompleted = true

		Task {
			await activity.end(
				ActivityContent(state: state, staleDate: nil),
				dismissalPolicy: .after(.now + 4)
			)
			self._activity = nil
		}
	}

	func cancel() {
		guard #available(iOS 16.2, *) else { return }
		guard let activity = _activity as? Activity<SigningActivityAttributes> else { return }

		Task {
			await activity.end(nil, dismissalPolicy: .immediate)
			self._activity = nil
		}
	}

	func endAll() {
		guard #available(iOS 16.2, *) else { return }
		for activity in Activity<SigningActivityAttributes>.activities {
			Task {
				await activity.end(nil, dismissalPolicy: .immediate)
			}
		}
		_activity = nil
	}
}
