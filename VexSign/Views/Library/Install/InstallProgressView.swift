//
//  InstallProgressView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 23.04.2025.
//

import SwiftUI
import IDeviceSwift
import NimbleExtensions

struct InstallProgressView: View {
	@State private var _isPulsing = false
	/// A pulsing icon is decoration: with Reduce Motion on it stays still. The identifier and the
	/// label are what a UI test and VoiceOver use.
	@Environment(\.accessibilityReduceMotion) private var _reduceMotion

	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel

	var body: some View {
		VStack(spacing: 12) {
			_appIcon()
				.scaleEffect(_reduceMotion ? 1 : (_isPulsing ? 0.85 : 0.81))
				.animation(
					_reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
					value: _isPulsing
				)
				.onAppear {
					_isPulsing = !_reduceMotion
				}
		}
		.accessibilityElement(children: .combine)
		.accessibilityLabel(.localized("Installing"))
		.accessibilityIdentifier(AX.Install.progress)
	}
	
	@ViewBuilder
	private func _appIcon() -> some View {
		ZStack {
			FRAppIconView(app: app)
				.opacity(0.2)
				.frame(width: 54, height: 54)
				.foregroundStyle(Color.black)
			
			FRAppIconView(app: app)
				.frame(width: 54, height: 54)
				.mask(
					ZStack {
						Circle().strokeBorder(Color.white, lineWidth: 4.5)
						PieShape(progress: viewModel.overallProgress)
							.scaleEffect(viewModel.isCompleted ? 2.2 : 1)
							.animation(.smooth, value: viewModel.isCompleted)
					}
				)
				.animation(.smooth, value: viewModel.overallProgress)
		}
	}
	
	struct PieShape: Shape {
		var progress: Double
		
		func path(in rect: CGRect) -> Path {
			var path = Path()
			let center = CGPoint(x: rect.midX, y: rect.midY)
			let radius = min(rect.width, rect.height) / 2
			let startAngle = Angle(degrees: -90)
			let endAngle = Angle(degrees: -90 + progress * 360)
			
			path.move(to: center)
			path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
			path.closeSubpath()
			
			return path
		}
		
		var animatableData: Double {
			get { progress }
			set { progress = newValue }
		}
	}
}
