//
//  FeatureStatusView.swift
//  VexSign
//
//  In-app view of the end-to-end feature status registry: every major
//  feature with its setting → persisted value → consumer chain and an
//  honest status. Settings → About → Feature Status.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct FeatureStatusView: View {
	@State private var _showingOnlyNeedsDevice = false

	private var filtered: [FeatureStatusEntry] {
		_showingOnlyNeedsDevice
			? FeatureStatusRegistry.entries.filter { $0.status == .needsDevice }
			: FeatureStatusRegistry.entries
	}

	var body: some View {
		NBList(.localized("Feature Status")) {
			NBSection(.localized("Overview")) {
				HStack(spacing: 12) {
					_counter(FeatureStatusRegistry.implementedCount, title: .localized("Implemented"), tint: .green, icon: "checkmark.circle.fill")
					_counter(FeatureStatusRegistry.needsDeviceCount, title: .localized("Needs Device"), tint: .orange, icon: "iphone.gen3")
				}
				.listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
				.listRowBackground(Color.clear)
				.accessibilityElement(children: .combine)
			} footer: {
				Text(.localized("Each feature is tracked end-to-end: setting → persisted value → signing/download/install consumer. 'Needs device validation' means the chain is wired but the last mile requires real hardware."))
			}

			NBSection(.localized("Features"), systemName: "checklist") {
				Toggle(isOn: $_showingOnlyNeedsDevice) {
					Label(.localized("Only needs-device items"), systemImage: "line.3.horizontal.decrease.circle")
				}
				.tint(Color.userTint)

				ForEach(filtered) { entry in
					_row(entry)
				}
			}
		}
	}

	private func _counter(_ value: Int, title: String, tint: Color, icon: String) -> some View {
		HStack(spacing: 10) {
			Image(systemName: icon)
				.font(.system(size: 20, weight: .semibold))
				.foregroundStyle(tint)
			VStack(alignment: .leading, spacing: 1) {
				Text("\(value)").font(.title3.bold().monospacedDigit())
				Text(title).font(.caption2).foregroundStyle(.secondary)
			}
			Spacer()
		}
		.padding(12)
		.frame(maxWidth: .infinity)
		.background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.accessibilityHidden(true)
	}

	private func _row(_ entry: FeatureStatusEntry) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				Text(entry.name)
					.font(.subheadline.weight(.semibold))
				Spacer()
				Label(entry.status.title, systemImage: entry.status == .implemented ? "checkmark.circle.fill" : "iphone.gen3")
					.font(.caption2.weight(.semibold))
					.foregroundStyle(entry.status == .implemented ? .green : .orange)
					.labelStyle(.titleAndIcon)
			}

			// Setting → persisted value → consumer, one line each.
			_pipelineRow(icon: "slider.horizontal.3", label: .localized("Setting"), value: entry.setting)
			_pipelineRow(icon: "cylinder.split.1x2", label: .localized("Persisted"), value: entry.persistedAs)
			_pipelineRow(icon: "gearshape.2", label: .localized("Consumer"), value: entry.consumer)
		}
		.padding(.vertical, 4)
		.accessibilityElement(children: .combine)
		.accessibilityLabel(Text(verbatim: "\(entry.name), \(entry.status.title)"))
	}

	private func _pipelineRow(icon: String, label: String, value: String) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: icon)
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(.secondary)
				.frame(width: 14)
			Text(label)
				.font(.caption2.weight(.semibold))
				.foregroundStyle(.secondary)
				.frame(width: 62, alignment: .leading)
			Text(verbatim: value)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}
