//
//  UIApplication+topController.swift
//  Loader
//
//  Created by VexSign TeamSign Team on 18.03.2025.
//

import UIKit

extension UIApplication {
	/// Root view controller of the key window in the active scene.
	///
	/// `UIApplication.shared.keyWindow` is deprecated: it returns a window across all
	/// connected scenes, which is the wrong answer for a multi-scene app.
	private static var _rootViewController: UIViewController? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		let keyWindow = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
		let window = keyWindow
			?? scenes.first { $0.activationState == .foregroundActive }?.windows.first
			?? scenes.first?.windows.first
		return window?.rootViewController
	}

	/// This belongs to https://stackoverflow.com/a/30858591
	public class func topViewController(controller: UIViewController? = nil) -> UIViewController? {
		guard let controller = controller ?? _rootViewController else { return nil }
		if let navigationController = controller as? UINavigationController {
			return topViewController(controller: navigationController.visibleViewController)
		}
		if let tabController = controller as? UITabBarController {
			if let selected = tabController.selectedViewController {
				return topViewController(controller: selected)
			}
		}
		if let presented = controller.presentedViewController {
			return topViewController(controller: presented)
		}
		return controller
	}
}
