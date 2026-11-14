//
//  AppLockScreenView.swift
//  VexSign
//
//  The full-screen cover shown while App Lock is engaged. Hides everything behind
//  a material and offers a manual unlock button for when the automatic prompt was
//  dismissed.
//

import SwiftUI
import NimbleExtensions

struct AppLockScreenView: View {
	@ObservedObject private var lock = AppLockManager.shared

	var body: some View {
		ZStack {
			Rectangle()
				.fill(.regularMaterial)
				.ignoresSafeArea()

			VStack(spacing: 20) {
				Image(systemName: "lock.shield")
					.font(.system(size: 56, weight: .medium))
					.foregroundStyle(Color.userTint)

				Text(.localized("VexSign is Locked"))
					.font(.title2.bold())

				if let message = lock.lastMessage {
					Text(message)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.padding(.horizontal, 32)
				}

				Button {
					lock.authenticate()
				} label: {
					Label(.localized("Unlock"), systemImage: "faceid")
						.font(.headline)
						.foregroundStyle(.white)
						.padding(.horizontal, 28)
						.padding(.vertical, 12)
						.background(Color.userTint, in: Capsule())
				}
				.padding(.top, 6)
				.disabled(lock.isAuthenticating)

				if lock.isAuthenticating {
					ProgressView()
				}
			}
		}
		.transition(.opacity)
	}
}
