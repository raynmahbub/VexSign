//
//  StorageConcurrency.swift
//  VexSign
//
//  The runtime half of the storage boundary: the legacy
//  synchronous mutators on `Storage` belong to the main-queue context, and one of
//  them being called from a detached task is the bug that surfaces later as a Core
//  Data "simultaneous access" crash, far from the line that caused it.
//
//  This is a diagnostic, not a gate. It records the caller and the call site
//  instead of trapping, because a trap would turn a background `saveContext()`
//  — which already hops to the main queue and is therefore not wrong — into a
//  crash. The compiler-enforced half of this boundary is a separate piece of work
//  (the annotations are what needs an Xcode pass, not the log line).
//

import Foundation
import OSLog

enum StorageConcurrency {
	/// Call at the top of anything that touches the main-queue `viewContext`
	/// synchronously. Off-main, the call is logged with the function and the
	/// source location that made it, so the guilty caller is in the log rather
	/// than in a crash report three screens later.
	static func requireMainQueue(
		function: StaticString = #function,
		file: StaticString = #fileID,
		line: UInt = #line
	) {
		guard !Thread.isMainThread else { return }
		Logger.misc.error(
			"Storage.\(function, privacy: .public) ran off the main queue (\(file, privacy: .public):\(line, privacy: .public)); writes belong on the write context."
		)
		#if DEBUG
		// Also on stderr: `Logger` output lives in the unified log, which a CI
		// run cannot read back, and this line is only interesting when it is
		// followed by a Core Data assertion a hundred lines later.
		NSLog("VexSign storage: %@ ran off the main queue (%@:%lu)", "\(function)", "\(file)", line)
		#endif
	}
}
