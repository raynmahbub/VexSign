//
//  TabBarSettingsView.swift
//  VexSign — five fixed primary tabs + customizable legacy tabs
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
                                Text(tab.title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.6)
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

            NBSection(.localized("Primary Tabs"), systemName: "square.grid.2x2.fill") {
                ForEach(TabBarPreferences.primaryTabs, id: \.self) { tab in
                    HStack {
                        Label(tab.title, systemImage: tab.icon)
                        Spacer()
                        Label(.localized("Locked"), systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
            } footer: {
                Text(.localized("Library, App Store, Home, Activity and Settings are the five default tabs. Library combines apps and files; Activity combines downloads, tasks and logs. Optional destinations can be enabled below. Five tabs use the native system tab bar, including Liquid Glass on iOS 26."))
            }

            NBSection(.localized("Legacy Tabs"), systemName: "square.stack.3d.up.fill") {
                ForEach(_prefs.order, id: \.self) { tab in
                    Toggle(isOn: Binding(
                        get: { !_prefs.isHidden(tab) },
                        set: { _prefs.setHidden(tab, !$0) }
                    )) {
                        Label(tab.title, systemImage: tab.icon)
                    }
                    .tint(Color.userTint)
                }
                .onMove { source, destination in
                    _prefs.moveSecondary(from: source, to: destination)
                }
            } footer: {
                Text(.localized("Optional destinations carried over from older versions. Show, hide and reorder them freely — they appear after the five primary tabs."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton().tint(Color.userTint) }
        }
    }
}
