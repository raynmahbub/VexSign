//
//  InstallQueueWindow.swift
//  VexSign
//
//  Created by VexSign Team on 24.08.2026.
//

import SwiftUI
import UIKit
import NimbleExtensions

/// Its own window because the download overlay or signing cover is often already presenting, and a
/// sheet on the root hierarchy would be silently dropped.
@MainActor
final class InstallQueueWindow {
	static let shared = InstallQueueWindow()

	private var _window: UIWindow?
	private var _retries = 0

	private init() {}

    private var makeRootView: (() -> AnyView)?
    private var mayTeardown: (() -> Bool)?
    func configure(makeRootView: @escaping () -> AnyView, mayTeardown: @escaping () -> Bool) {
        self.makeRootView = makeRootView
        self.mayTeardown = mayTeardown
    }

	func ensure() {
		guard _window == nil, let makeRootView else { return }

		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
			?? scenes.first(where: { $0.activationState == .foregroundInactive })
			?? scenes.first
		else {
			guard _retries < 20 else { return }
			_retries += 1
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.ensure() }
			return
		}

		_retries = 0

		let host = UIHostingController(rootView: makeRootView())
		host.view.backgroundColor = .clear
		host.view.isOpaque = false

		let window = InstallPassthroughWindow(windowScene: scene)
		window.windowLevel = .alert
		window.backgroundColor = .clear
		window.isOpaque = false
		window.rootViewController = host
		window.isHidden = false

		_window = window
	}

	func teardown() {
		DispatchQueue.main.async {
			guard self.mayTeardown?() == true else { return }
			self._window?.isHidden = true
			self._window = nil
		}
	}
}

/// Nothing but the sheet lives here, so other touches belong to the app.
private final class InstallPassthroughWindow: UIWindow {
	override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
		guard rootViewController?.presentedViewController != nil else { return nil }
		return super.hitTest(point, with: event)
	}
}
