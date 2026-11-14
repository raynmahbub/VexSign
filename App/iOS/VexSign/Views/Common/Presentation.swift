//
//  Presentation.swift
//  VexSign
//
//  Created by VexSign Team
//

import UIKit
import NimbleExtensions

/// Defers work until nothing is mid transition. SwiftUI drops a sheet set while a menu, alert or
/// picker is still dismissing.
enum Presentation {
	private static let _tick = 0.05
	private static let _maxTicks = 30

	static func afterDismiss(_ work: @escaping () -> Void) {
		guard let root = _rootViewController() else { return work() }
		_wait(root, 0, work)
	}

	/// Root view controller of the active scene's key window.
	/// `UIApplication.keyWindow` is deprecated and spans every connected scene.
	private static func _rootViewController() -> UIViewController? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		let keyWindow = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
		let window = keyWindow
			?? scenes.first { $0.activationState == .foregroundActive }?.windows.first
			?? scenes.first?.windows.first
		return window?.rootViewController
	}

	private static func _wait(_ root: UIViewController, _ tick: Int, _ work: @escaping () -> Void) {
		let top = _topmost(root)
		guard top.isBeingDismissed || top.transitionCoordinator != nil, tick < _maxTicks else { return work() }
		DispatchQueue.main.asyncAfter(deadline: .now() + _tick) { _wait(root, tick + 1, work) }
	}

	private static func _topmost(_ controller: UIViewController) -> UIViewController {
		controller.presentedViewController.map(_topmost) ?? controller
	}
}
