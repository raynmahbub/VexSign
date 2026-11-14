//
//  InstallCleanup.swift
//  VexSign
//
//  Compatibility shim: the actual cleanup logic now lives in `CleanupManager`, which also runs
//  after signing, downloads and on demand. These constants and calls are kept so the older
//  toggles (Signing Options → Delete After Installing, Storage → Clear Cache After Installing)
//  and every existing call site keep working unchanged.
//

import Foundation

@MainActor
enum InstallCleanup {
	/// Kept for the toggles that were already shipped with these keys.
	static let deleteKey = CleanupManager.Key.deleteAfterInstall
	static let clearCacheKey = CleanupManager.Key.clearCache

	/// Parks the app until the install UI is gone.
	static func stage(_ app: AppInfoPresentable) {
		CleanupManager.shared.stage(app)
	}

	/// Runs every toggle in Settings → Auto Cleanup that applies to a finished install.
	static func flush() {
		CleanupManager.shared.flush()
	}

	/// Same sweep at cold launch, where a toast would be noise: a job killed mid-install left
	/// apps behind and they are removed quietly.
	static func flushOnLaunch() {
		CleanupManager.shared.flush(silent: true)
	}
}
