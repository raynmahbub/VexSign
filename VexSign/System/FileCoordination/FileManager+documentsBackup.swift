//
//  FileManager+documentsBackup.swift
//  VexSign
//
//  The device-backup half of the Documents policy. `FileManager+documents.swift`
//  is a preserved input from the migration and stays byte-identical, so the rule
//  that decides which folders ride into an iCloud/iTunes backup lives here.
//

import Foundation

extension FileManager {

	/// Marks a directory as excluded from iCloud/iTunes device backups.
	///
	/// Used for the folders under Documents that are *derived* rather than authored:
	/// re-downloadable firmware, the transient Web Manager inbox and the diagnostic
	/// logs. The library folders (`Archives`, `Signed`, `Unsigned`, `Tweaks`,
	/// `Entitlements`) are deliberately **not** excluded — they are the user's
	/// content, and moving them between devices is what the password-protected
	/// Backup feature is for.
	///
	/// A missing directory is not an error: the caller is usually iterating the
	/// launch-time sweep, and a folder that does not exist yet cannot be backed up.
	/// - Parameter logFailure: pass `false` from the logging path itself, where a
	///   warning would re-enter the writer that just failed.
	@discardableResult
	func excludeFromBackup(_ url: URL, logFailure: Bool = true) -> Bool {
		guard fileExists(atPath: url.path) else { return false }
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		var mutable = url
		do {
			try mutable.setResourceValues(values)
			return true
		} catch {
			if logFailure {
				SubsystemDiagnosticsLog.warn(
					"Could not exclude \(url.lastPathComponent) from device backups: \(error.localizedDescription)",
					subsystem: .storage
				)
			}
			return false
		}
	}
}
