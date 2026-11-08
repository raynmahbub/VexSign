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
	/// - Parameter identifier: Application identifier
	static public func openApp(with identifier: String) {
		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" 			// LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="     			// defaultWorkspace
		let openSelectorBase64 = "b3BlbkFwcGxpY2F0aW9uV2l0aEJ1bmRsZUlEOg==" // openApplicationWithBundleID:
		
		guard
			let classNameData = Data(base64Encoded: classNameBase64),
			let defaultSelectorData = Data(base64Encoded: defaultSelectorBase64),
			let openSelectorData = Data(base64Encoded: openSelectorBase64),
			let className = String(data: classNameData, encoding: .utf8),
			let defaultSelector = String(data: defaultSelectorData, encoding: .utf8),
			let openSelector = String(data: openSelectorData, encoding: .utf8)
		else {
			return
		}
		
		guard
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
		else {
			return
		}
		
		_ = workspace.perform(NSSelectorFromString(openSelector), with: identifier)
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
