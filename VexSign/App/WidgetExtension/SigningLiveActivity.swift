//
//  SigningLiveActivity.swift
//  VexSignWidgetExtension
//
//  Live Activity view for app signing
//

import ActivityKit
import WidgetKit
import SwiftUI

struct SigningLiveActivity: Widget {
	var body: some WidgetConfiguration {
		ActivityConfiguration(for: SigningActivityAttributes.self) { context in
			// Lock screen / Banner UI
			SigningLiveActivityView(context: context)
				.activityBackgroundTint(Color.black.opacity(0.3))
				.activitySystemActionForegroundColor(Color.white)
		} dynamicIsland: { context in
			DynamicIsland {
				DynamicIslandExpandedRegion(.center) {
					VStack(spacing: 6) {
						Text(context.state.appName)
							.font(.subheadline)
							.fontWeight(.medium)
							.lineLimit(1)
							.truncationMode(.tail)
							.multilineTextAlignment(.center)

						HStack(spacing: 8) {
							ZStack {
								Circle()
									.stroke(Color.purple.opacity(0.3), lineWidth: 2)
								Circle()
									.trim(from: 0, to: context.state.isCompleted ? 1 : CGFloat(max(0.05, context.state.progress)))
									.stroke(context.state.isCompleted ? Color.green : Color.purple, style: StrokeStyle(lineWidth: 2, lineCap: .round))
									.rotationEffect(.degrees(-90))
								Image(systemName: context.state.isCompleted ? "checkmark" : "signature")
									.font(.system(size: 11))
									.foregroundColor(context.state.isCompleted ? .green : .purple)
							}
							.frame(width: 24, height: 24)

							ProgressView(value: context.state.isCompleted ? 1.0 : context.state.progress)
								.tint(context.state.isCompleted ? Color.green : Color.purple)
								.frame(maxWidth: .infinity)
								.scaleEffect(x: 1, y: 1.5, anchor: .center)

							Text(context.state.status)
								.font(.caption)
								.fontWeight(.semibold)
								.foregroundColor(context.state.isCompleted ? .green : .purple)
						}

						if context.state.totalApps > 1 {
							Text("\(context.state.currentApp) of \(context.state.totalApps) apps")
								.font(.caption2)
								.foregroundColor(.secondary)
						}
					}
					.padding(.horizontal, 8)
				}
				DynamicIslandExpandedRegion(.leading) { EmptyView() }
				DynamicIslandExpandedRegion(.trailing) { EmptyView() }
				DynamicIslandExpandedRegion(.bottom) { EmptyView() }
			} compactLeading: {
				HStack(spacing: 4) {
					Image(systemName: context.state.isCompleted ? "checkmark.circle.fill" : "signature")
						.font(.system(size: 11))
						.foregroundColor(context.state.isCompleted ? .green : .purple)
				}
			} compactTrailing: {
				if context.state.isCompleted {
					Text("Done")
						.font(.caption2)
						.fontWeight(.semibold)
						.foregroundColor(.green)
				} else {
					Text("\(Int(context.state.progress * 100))%")
						.font(.caption2)
						.fontWeight(.semibold)
						.foregroundColor(.purple)
				}
			} minimal: {
				Image(systemName: context.state.isCompleted ? "checkmark.circle.fill" : "signature")
					.font(.system(size: 10))
					.foregroundColor(context.state.isCompleted ? .green : .purple)
			}
			.widgetURL(URL(string: "vexsign://library"))
			.keylineTint(.purple)
		}
	}
}

struct SigningLiveActivityView: View {
	let context: ActivityViewContext<SigningActivityAttributes>

	var body: some View {
		VStack(spacing: 8) {
			HStack(spacing: 10) {
				ZStack {
					Circle()
						.stroke(Color.purple.opacity(0.3), lineWidth: 3)
					Circle()
						.trim(from: 0, to: context.state.isCompleted ? 1 : CGFloat(max(0.05, context.state.progress)))
						.stroke(context.state.isCompleted ? Color.green : Color.purple, style: StrokeStyle(lineWidth: 3, lineCap: .round))
						.rotationEffect(.degrees(-90))
					Image(systemName: context.state.isCompleted ? "checkmark" : "signature")
						.font(.system(size: 13))
						.foregroundColor(context.state.isCompleted ? .green : .purple)
				}
				.frame(width: 28, height: 28)

				VStack(alignment: .leading, spacing: 2) {
					Text(context.state.appName)
						.font(.subheadline)
						.fontWeight(.bold)
						.lineLimit(1)
						.truncationMode(.tail)

					Text(context.state.totalApps > 1
						? "\(context.state.status) (\(context.state.currentApp)/\(context.state.totalApps))"
						: context.state.status)
						.font(.caption)
						.foregroundColor(.secondary)
				}

				Spacer()

				Text("\(Int((context.state.isCompleted ? 1.0 : context.state.progress) * 100))%")
					.font(.title3)
					.fontWeight(.bold)
					.foregroundColor(context.state.isCompleted ? .green : .purple)
			}

			ProgressView(value: context.state.isCompleted ? 1.0 : context.state.progress)
				.tint(context.state.isCompleted ? Color.green : Color.purple)
		}
		.padding(16)
	}
}
