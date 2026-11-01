//
//  UIApplication+topController.swift
//  Loader
//
//  Created by VexSign TeamSign Team on 18.03.2025.
//

import UIKit

extension UIApplication {
	/// This belongs to https://stackoverflow.com/a/30858591
	public class func topViewController() -> UIViewController? {
		topViewController(controller: keyWindowRootViewController)
	}

	/// The root controller of the window the user is currently looking at.
	///
	/// `UIApplication.keyWindow` is deprecated because it returns a key window
	/// across *all* connected scenes, which is the wrong one on iPad or with a
	/// second scene. Prefer the foreground-active scene and fall back to the
	/// others only when nothing is active (during a transition, for instance).
	internal class var keyWindowRootViewController: UIViewController? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		let ordered = scenes.filter { $0.activationState == .foregroundActive } + scenes.filter { $0.activationState != .foregroundActive }
		for scene in ordered {
			if let window = scene.windows.first(where: { $0.isKeyWindow }) {
				return window.rootViewController
			}
		}
		return ordered.first?.windows.first?.rootViewController
	}

	public class func topViewController(controller: UIViewController?) -> UIViewController? {
		if let navigationController = controller as? UINavigationController {
			return topViewController(controller: navigationController.visibleViewController)
		}
		if let tabController = controller as? UITabBarController {
			if let selected = tabController.selectedViewController {
				return topViewController(controller: selected)
			}
		}
		if let presented = controller?.presentedViewController {
			return topViewController(controller: presented)
		}
		return controller
	}
}
