//
//  DownloadPreferences.swift
//  VexSign
//
//  Wi-Fi-only, parallel cap, and "resume when Game Mode turns off" — the reliability
//  knobs that sit on top of DownloadManager without replacing its session machinery.
//

import Foundation
import Network
import UIKit
import NimbleExtensions

enum DownloadPreferences {
    static let pathChanged = Notification.Name("VexSign.downloadPathChanged")
	static let wifiOnlyKey = "VexSign.downloads.wifiOnly"
	static let chargeOnlyKey = "VexSign.downloads.chargeOnly"
	static let maxParallelKey = "VexSign.downloads.maxParallel"
	static let resumeAfterGameModeKey = "VexSign.downloads.resumeAfterGameMode"

	static var wifiOnly: Bool {
		get { UserDefaults.standard.bool(forKey: wifiOnlyKey) }
		set { UserDefaults.standard.set(newValue, forKey: wifiOnlyKey) }
	}

	static var chargeOnly: Bool {
		get { UserDefaults.standard.bool(forKey: chargeOnlyKey) }
		set { UserDefaults.standard.set(newValue, forKey: chargeOnlyKey) }
	}

	/// 1…8 simultaneous network downloads. Default 3 so a big IPA does not starve the rest.
	static var maxParallel: Int {
		get {
			let value = UserDefaults.standard.object(forKey: maxParallelKey) as? Int ?? 3
			return min(8, max(1, value))
		}
		set { UserDefaults.standard.set(min(8, max(1, newValue)), forKey: maxParallelKey) }
	}

	static var resumeAfterGameMode: Bool {
		get {
			if UserDefaults.standard.object(forKey: resumeAfterGameModeKey) == nil { return true }
			return UserDefaults.standard.bool(forKey: resumeAfterGameModeKey)
		}
		set { UserDefaults.standard.set(newValue, forKey: resumeAfterGameModeKey) }
	}

	/// Cellular / expensive path when Wi-Fi-only is on.
	static var isOnExpensivePath: Bool {
		PathMonitor.shared.isExpensive
	}

	/// True while plugged in (or the battery is full). Battery monitoring is enabled
	/// on the spot so the check is self-contained.
	static var isCharging: Bool {
		UIDevice.current.isBatteryMonitoringEnabled = true
		let state = UIDevice.current.batteryState
		return state == .charging || state == .full
	}

	static func etaString(bytesRemaining: Int64, bytesPerSecond: Int64) -> String? {
		guard bytesPerSecond > 0, bytesRemaining > 0 else { return nil }
		let seconds = Double(bytesRemaining) / Double(bytesPerSecond)
		if seconds < 60 { return String.localized("%llds left", arguments: Int(seconds.rounded())) }
		if seconds < 3600 { return String.localized("%lldm left", arguments: Int((seconds / 60).rounded())) }
		return String.localized("%lldh left", arguments: Int((seconds / 3600).rounded()))
	}
}

/// Shared NWPathMonitor so we do not spin one up per download.
private final class PathMonitor {
	static let shared = PathMonitor()

	private let monitor = NWPathMonitor()
	private let queue = DispatchQueue(label: "vexsign.path")
    private let lock = NSLock()
    private var expensive = true // Unknown connectivity must not bypass Wi-Fi-only admission.
    var isExpensive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expensive
    }

	private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let blocked = path.status != .satisfied || path.isExpensive || path.isConstrained || path.usesInterfaceType(.cellular)
            self.lock.lock()
            self.expensive = blocked
            self.lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: DownloadPreferences.pathChanged, object: nil)
            }
        }
		monitor.start(queue: queue)
	}
}
