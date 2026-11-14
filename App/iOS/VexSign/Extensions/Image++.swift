//
//  Image+appIconStyle.swift
//  VexSign
//
//  Created by VexSign Contributors on 11.04.2025.
//

import SwiftUI

extension Image {
	/// Applies a standard icon style with firmware-aware corner radius
	func appIconStyle(
		size: CGFloat = 56,
		lineWidth: CGFloat = 1,
		isCircle: Bool = false,
		background: Color = .clear,
		tint: Color? = nil
	) -> some View {
		var multiplier: CGFloat = 0.2337
		if #available(iOS 26.0, *) {
			multiplier = 0.2677
		}

		let radius = isCircle ? (size / 2) : (size * multiplier)

		let image: Image = {
			guard tint != nil else { return self }
			return self.renderingMode(.template)
		}()

		let base: AnyView = {
			let resized = image
				.resizable()
				.scaledToFit()
				.frame(width: size, height: size)

			if let tint {
				return AnyView(resized.foregroundStyle(tint))
			}
			return AnyView(resized)
		}()

		return base
			.background(
				RoundedRectangle(cornerRadius: radius, style: .continuous)
					.fill(background)
			)
			.overlay {
				RoundedRectangle(cornerRadius: radius, style: .continuous)
					.strokeBorder(Color.primary.opacity(0.15), lineWidth: lineWidth)
			}
			.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
	}
}
