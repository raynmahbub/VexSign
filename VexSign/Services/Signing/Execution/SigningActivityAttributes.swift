//
//  SigningActivityAttributes.swift
//  VexSign
//
//  Live Activity attributes for signing and batch signing progress.
//

import Foundation
import ActivityKit

public struct SigningActivityAttributes: ActivityAttributes {
	public struct ContentState: Codable, Hashable {
		public var appName: String
		public var progress: Double
		public var status: String
		public var currentApp: Int
		public var totalApps: Int
		public var isCompleted: Bool

		public init(
			appName: String,
			progress: Double = 0.0,
			status: String = "Signing…",
			currentApp: Int = 1,
			totalApps: Int = 1,
			isCompleted: Bool = false
		) {
			self.appName = appName
			self.progress = progress
			self.status = status
			self.currentApp = currentApp
			self.totalApps = totalApps
			self.isCompleted = isCompleted
		}
	}

	public var startTime: Date

	public init(startTime: Date = Date()) {
		self.startTime = startTime
	}
}
