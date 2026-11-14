//
//  Logger++.swift
//  VexSign
//
//  Created by VexSign Contributors on 24.05.2025.
//

import OSLog

extension Logger {
	private static var subsystem = Bundle.main.bundleIdentifier ?? "com.vexsign.app"
	static let signing = Logger(subsystem: subsystem, category: "Signing")
	static let misc = Logger(subsystem: subsystem, category: "Misc")
	static let security = Logger(subsystem: subsystem, category: "Security")
}
