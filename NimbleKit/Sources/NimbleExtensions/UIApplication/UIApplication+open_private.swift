//
//  UIApplication+open.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 21.04.2025.
//

import UIKit.UIApplication
import ObjectiveC

extension UIApplication {
	/// Opens an app with an identifier
	///
	/// This depends on LaunchServices private API, which Apple can filter or remove in any iOS
	/// release. Both selectors are therefore checked before being sent: `perform(_:)` on a method
	/// that does not exist raises `doesNotRecognizeSelector:` and terminates the app, so the old
	/// unguarded path turned "this iOS build lacks a private API" into a crash on Open.
	///
	/// - Parameter identifier: Application identifier
	/// - Returns: `true` only when the launch request was handed to a workspace that actually
	///   implements it. `false` means the private API is unavailable on this iOS version or the
	///   identifier was empty, so callers must not present the action as if it had worked. iOS
	///   does not confirm that the target app reached the foreground: `true` means *dispatched*,
	///   never *launched*. There is no public API that can launch another app by bundle
	///   identifier, so there is no fallback to degrade to — the honest answer is failure.
	@discardableResult
	static public func openApp(with identifier: String) -> Bool {
		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" 			// LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="     			// defaultWorkspace
		let openSelectorBase64 = "b3BlbkFwcGxpY2F0aW9uV2l0aEJ1bmRsZUlEOg==" // openApplicationWithBundleID:

		guard !identifier.isEmpty else { return false }

		guard
			let classNameData = Data(base64Encoded: classNameBase64),
			let defaultSelectorData = Data(base64Encoded: defaultSelectorBase64),
			let openSelectorData = Data(base64Encoded: openSelectorBase64),
			let className = String(data: classNameData, encoding: .utf8),
			let defaultSelector = String(data: defaultSelectorData, encoding: .utf8),
			let openSelector = String(data: openSelectorData, encoding: .utf8)
		else {
			return false
		}

		guard
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			class_getClassMethod(workspaceClass, NSSelectorFromString(defaultSelector)) != nil,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?
				.takeUnretainedValue() as? NSObject
		else {
			return false
		}

		let selector = NSSelectorFromString(openSelector)
		guard workspace.responds(to: selector),
		      let implementation = workspace.method(for: selector) else {
			return false
		}

		// The Objective-C method returns a primitive BOOL, not an object, so it is dispatched
		// through its real calling convention instead of `perform(_:with:)`, which would
		// reinterpret that BOOL as a pointer.
		typealias Open = @convention(c) (AnyObject, Selector, NSString) -> Void
		unsafeBitCast(implementation, to: Open.self)(workspace, selector, identifier as NSString)
		return true
	}

	/// Returns install progress for a bundle identifier (0.0 – 1.0)
	/// - Parameters:
	///   - identifier: Bundle identifier
	///   - synchronous: Whether the call should block
	/// - Returns: Progress value if available
	static public func installProgress(
		for identifier: String,
		makeSynchronous synchronous: Bool = true
	) -> Double? {

		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" // LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="   // defaultWorkspace
		let progressSelectorBase64 = "aW5zdGFsbFByb2dyZXNzRm9yQnVuZGxlSUQ6bWFrZVN5bmNocm9ub3VzOg==" // installProgressForBundleID:makeSynchronous:

        guard let classNameData = Data(base64Encoded: classNameBase64),
              let defaultSelectorData = Data(base64Encoded: defaultSelectorBase64),
              let progressSelectorData = Data(base64Encoded: progressSelectorBase64),
              let className = String(data: classNameData, encoding: .utf8),
              let defaultName = String(data: defaultSelectorData, encoding: .utf8),
              let progressName = String(data: progressSelectorData, encoding: .utf8),
              let workspaceClass = NSClassFromString(className) as? NSObject.Type,
              class_getClassMethod(workspaceClass, NSSelectorFromString(defaultName)) != nil,
              let workspace = workspaceClass.perform(NSSelectorFromString(defaultName))?.takeUnretainedValue() as? NSObject else { return nil }
        let selector = NSSelectorFromString(progressName)
        guard workspace.responds(to: selector), let implementation = workspace.method(for: selector) else { return nil }
        // The second argument is a native BOOL, not an NSNumber pointer passed
        // by perform(_:with:with:). Use the actual Objective-C calling convention.
        typealias Query = @convention(c) (AnyObject, Selector, NSString, Bool) -> Unmanaged<AnyObject>?
        let query = unsafeBitCast(implementation, to: Query.self)
        guard let progress = query(workspace, selector, identifier as NSString, synchronous)?.takeUnretainedValue() as? Progress else { return nil }
        let fraction = progress.fractionCompleted
        return fraction.isFinite ? min(1, max(0, fraction)) : nil
    }
}
