//
//  TabBarSettingsView.swift
//  VexSign — configurable tab order and visibility
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct TabBarSettingsView: View {
    @ObservedObject private var _prefs = TabBarPreferences.shared

    var body: some View {
        NBList(.localized("Tab Bar"), type: .list) {
            // Live preview of the resolved defaults and optional destinations
            NBSection(.localized("Preview")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(_prefs.visibleTabs, id: \.self) { tab in
                            VStack(spacing: 4) {
                                Image(systemName: tab.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.tint)
                                if _prefs.showLabels {
                                    Text(tab.title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.6)
                                }
                            }
                            .frame(width: 56)
                            .padding(.vertical, 8)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(Text(tab.title))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
            } footer: {
                Text(verbatim: String.localized("Your current order: %@.", arguments: _prefs.visibleTabs.map { $0.title }.joined(separator: " • ")))
            }

            NBSection(.localized("Default Launch Tab")) {
                Picker(selection: $_prefs.defaultLaunch) {
                    ForEach(_prefs.visibleTabs, id: \.self) { tab in
                        Label(tab.title, systemImage: tab.icon).tag(tab)
                    }
                } label: {
                    Label(.localized("Open On Launch"), systemImage: "house.fill")
                }
                .pickerStyle(.menu)
                .tint(Color.userTint)
            } footer: {
                Text(.localized("Which tab the app opens to."))
            }

            NBSection(.localized("Tab Labels"), systemName: "textformat") {
                Toggle(.localized("Show Tab Labels"), isOn: $_prefs.showLabels)
                    .tint(Color.userTint)
            } footer: {
                Text(.localized("Hide tab titles for a compact icon-only bar. VoiceOver labels remain available."))
            }

            NBSection(.localized("Customize Tabs"), systemName: "square.stack.3d.up.fill") {
                ForEach(_prefs.orderedTabs, id: \.self) { tab in
                    if _prefs.isHideable(tab) {
                        Toggle(isOn: Binding(
                            get: { !_prefs.isHidden(tab) },
                            set: { _prefs.setHidden(tab, !$0) }
                        )) {
                            Label(tab.title, systemImage: tab.icon)
                        }
                        .tint(Color.userTint)
                    } else {
                        HStack {
                            Label(tab.title, systemImage: tab.icon)
                            Spacer()
                            Label(.localized("Required"), systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { source, destination in
                    _prefs.move(from: source, to: destination)
                }
            } footer: {
                Text(.localized("Reorder any tab and hide destinations you do not use. Home and Settings stay visible so you can always return here and restore your navigation. The tab bar adapts to the number of visible destinations."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton().tint(Color.userTint) }
        }
    }
}
