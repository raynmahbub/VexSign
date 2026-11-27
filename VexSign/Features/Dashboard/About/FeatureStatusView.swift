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
					_counter(FeatureStatusRegistry.implementedCount, title: .localized("Source present"), tint: .green, icon: "checkmark.circle.fill")
					_counter(FeatureStatusRegistry.needsDeviceCount, title: .localized("Needs Device"), tint: .orange, icon: "iphone.gen3")
				}
				.listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
				.listRowBackground(Color.clear)
				.accessibilityElement(children: .combine)
					.accessibilityLabel(Text(verbatim: String.localized("%lld source present, %lld need device validation", arguments: Int64(FeatureStatusRegistry.implementedCount), Int64(FeatureStatusRegistry.needsDeviceCount))))
			} footer: {
				Text(.localized("Each feature is tracked end-to-end: setting → persisted value → signing/download/install consumer. 'Source present' means the chain is wired, not that a build or device pass was observed. 'Needs device validation' means the last mile requires real hardware."))
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
				.font(.title3.weight(.semibold))
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
		// The counters carry the only numbers in this row; hiding them made the
		// overview silent. They are combined by the section, not duplicated here.
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
		.accessibilityLabel(Text(verbatim: String.localized("%@, %@", arguments: entry.name, entry.status.title)))
	}

	private func _pipelineRow(icon: String, label: String, value: String) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: icon)
				.font(.caption2.weight(.semibold))
				.foregroundStyle(.secondary)
				.frame(width: 14)
				.accessibilityHidden(true)
			Text(label)
				.font(.caption2.weight(.semibold))
				.foregroundStyle(.secondary)
				// A minimum, not a maximum: translated labels and large text grow
				// instead of being clipped at the old 62-point width.
				.frame(minWidth: 62, alignment: .leading)
			Text(verbatim: value)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}
