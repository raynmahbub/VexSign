//
//  AppearanceView.swift
//  VexSign — organized, tint-coherent appearance settings
//
import SwiftUI
import NimbleViews
import UIKit
import NimbleExtensions

struct AppearanceView: View {
    @AppStorage("VexSign.userInterfaceStyle") private var _userIntefacerStyle: Int = UIUserInterfaceStyle.unspecified.rawValue

    @AppStorage("VexSign.storeCellAppearance") private var _storeCellAppearance: Int = 0
    private let _storeCellAppearanceMethods: [(name: String, desc: String)] = [
        (.localized("Standard"), .localized("Default style for the app, only includes subtitle.")),
        (.localized("Big Description"), .localized("Adds the localized description of the app."))
    ]

    @AppStorage("VexSign.showSourcesUpdateBadge") private var _showSourcesUpdateBadge: Bool = true
    @AppStorage("VexSign.shouldTintIcons") private var _shouldTintIcons: Bool = false
    @AppStorage("VexSign.shouldChangeIconsBasedOffStyle") private var _shouldChangeIconsBasedOffStyle: Bool = false
    @AppStorage("VexSign.userTintColor") private var _selectedColorHex: String = "#848ef9"

    /// Theme/font/animation preferences go through the shared appearance store
    /// so every observer (app root, tab bar, motion modifiers) updates at once.
    @ObservedObject private var _appearance = AppearanceStore.shared
    @State private var confirmResetAppearance = false

    private var _fontFamilyBinding: Binding<String> {
        Binding(
            get: { _appearance.fontFamily.rawValue },
            set: { _appearance.setFontFamily(VexSignFontFamily(rawValue: $0) ?? .system) }
        )
    }

    private var _fontScaleBinding: Binding<Double> {
        Binding(
            get: { _appearance.fontScale },
            set: { _appearance.setFontScale($0) }
        )
    }

    private var _flareAnimationsBinding: Binding<Bool> {
        Binding(
            get: { _appearance.animationsEnabled },
            set: { _appearance.setAnimationsEnabled($0) }
        )
    }

    private var _tintColorBinding: Binding<Color> {
        Binding(
            get: { Color.userTint },
            set: { _selectedColorHex = $0.toHex() }
        )
    }

    private func themeSwatch(_ theme: VexSignVisualTheme) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.background(for: theme))
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Color(hex: theme.defaultAccentHex)).frame(width: 22, height: 4)
                RoundedRectangle(cornerRadius: 4).fill(Theme.card(for: theme)).frame(height: 15)
                RoundedRectangle(cornerRadius: 4).fill(Theme.card(for: theme)).frame(height: 8)
            }
            .padding(8)
        }
        .frame(width: 58, height: 58)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).stroke(Color.secondary.opacity(0.25)))
        .preferredColorScheme(theme.preferredColorScheme)
        .accessibilityHidden(true)
    }

    var body: some View {
        NBList(.localized("Appearance")) {
            Section {
                WorkspaceCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        Label(.localized("Your signing workspace"), systemImage: "signature")
                            .font(.headline)
                        Text(.localized("A readable preview of your current theme and typography."))
                            .foregroundStyle(.secondary)
                        HStack {
                            Label(.localized("Ready to customize"), systemImage: "slider.horizontal.3")
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark.circle").foregroundStyle(Theme.tint)
                        }
                        .font(.subheadline)
                        Text("com.example.app").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .listRowInsets(EdgeInsets())
            } header: { Text(.localized("Live Preview")) }
            Section {
                Picker(.localized("Appearance"), selection: $_userIntefacerStyle) {
                    ForEach(UIUserInterfaceStyle.allCases.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(_appearance.visualTheme.preferredColorScheme != nil)
            } header: {
                Label(.localized("Interface Style"), systemImage: "moonphase")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.userTint)
            }

            // Organized theme section — tint picker grouped, not a loose horizontal strip
            NBSection(.localized("Theme")) {
                AppearanceTintColorView()
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            } footer: {
                Text(.localized("The tint colors navigation, buttons and highlights across the app."))
            }

            NBSection(.localized("Visual Theme"), systemName: "paintpalette") {
                ForEach(VexSignVisualTheme.allCases) { theme in
                    Button {
                        _appearance.setVisualTheme(theme)
                    } label: {
                        HStack(spacing: Theme.Spacing.medium) {
                            themeSwatch(theme)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                                Text(theme.title).font(.headline).foregroundStyle(.primary)
                                Text(theme.description).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if _appearance.visualTheme == theme {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.tint)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.xSmall)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(_appearance.visualTheme == theme ? .isSelected : [])
                }
            } footer: {
                Text(.localized("System follows your interface style. Other presets select their own light or dark surfaces. Your custom accent is preserved; Luna and Flare remain available for existing users."))
            }

            Section {
                ColorPicker(.localized("Custom Theme Color"), selection: _tintColorBinding, supportsOpacity: false)
                    .tint(Color.userTint)
                Button(.localized("Use theme accent")) {
                    UserDefaults.standard.removeObject(forKey: "VexSign.userTintColor")
                }
            } footer: {
                Text(.localized("Pick any color if the presets don’t fit. It updates instantly."))
            }

            NBSection(.localized("Font & Motion"), systemName: "textformat") {
                Picker(.localized("Font"), selection: _fontFamilyBinding) {
                    ForEach(VexSignFontFamily.allCases) { family in
                        Text(family.title)
                            .font(.system(.body, design: family.design))
                            .tag(family.rawValue)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("A")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: _fontScaleBinding, in: 0.9...1.15, step: 0.05)
                        .tint(Color.userTint)
                    Text("A")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.userTint)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(.localized("Font size")))

                Toggle(.localized("Button feedback animations"), isOn: _flareAnimationsBinding)
                    .tint(Color.userTint)
            } footer: {
                Text(.localized("System typography is recommended. Font sizing follows Dynamic Type; technical identifiers keep monospaced styling. Button feedback respects Reduce Motion."))
            }

            if #available(iOS 18.0, *) {
                NBSection(.localized("Library Icons")) {
                    Toggle(.localized("Dynamic Icons"), isOn: $_shouldChangeIconsBasedOffStyle)
                        .tint(Color.userTint)
                    if #available(iOS 18.2, *) {
                        Toggle(.localized("Tinted Icons"), isOn: $_shouldTintIcons)
                            .tint(Color.userTint)
                    }
                } footer: {
                    Text(.localized("Tinted icons use your theme color. Dynamic icons adapt to light & dark."))
                }
            }

            NBSection(.localized("App Store"), systemName: "bag.fill") {
                Picker(.localized("Store Cell Appearance"), selection: $_storeCellAppearance) {
                    ForEach(0..<_storeCellAppearanceMethods.count, id: \.self) { index in
                        let method = _storeCellAppearanceMethods[index]
                        NBTitleWithSubtitleView(title: method.name, subtitle: method.desc).tag(index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
                Toggle(.localized("Update Count Badge"), isOn: $_showSourcesUpdateBadge).tint(Color.userTint)
                NavigationLink(destination: IgnoredUpdatesView()) {
                    Label(.localized("Ignored Updates"), systemImage: "bell.slash")
                }
            } footer: {
                Text(.localized("The App Store owns repository browsing, source refresh, updates, and app discovery. The update count badge appears on its primary tab."))
            }

            Section {
                Button(.localized("Reset workspace appearance")) { confirmResetAppearance = true }
            } footer: {
                Text(.localized("Restores System theme, system font, default text scale and button feedback. Certificates, apps and signing options are not changed."))
            }

            NBSection(.localized("Liquid Glass"), systemName: "circle.lefthalf.filled") {
                if #available(iOS 26.0, *) {
                    Text(.localized("Native glass is used for supported navigation and actions. Content surfaces stay readable and respect Reduce Transparency."))
                } else {
                    Text(.localized("Native Liquid Glass requires iOS 26. This device uses standard system navigation and opaque content surfaces."))
                }
            }
        }
        .confirmationDialog(.localized("Reset workspace appearance?"), isPresented: $confirmResetAppearance, titleVisibility: .visible) {
            Button(.localized("Reset workspace appearance"), role: .destructive) {
                _appearance.setVisualTheme(.system)
                _appearance.setFontFamily(.system)
                _appearance.setFontScale(1)
                _appearance.setAnimationsEnabled(true)
                _userIntefacerStyle = UIUserInterfaceStyle.unspecified.rawValue
                UserDefaults.standard.removeObject(forKey: "VexSign.userTintColor")
            }
            Button(.localized("Cancel"), role: .cancel) {}
        }
        .onChange(of: _userIntefacerStyle) { value in
            if let style = UIUserInterfaceStyle(rawValue: value) {
                UIApplication.topViewController()?.view.window?.overrideUserInterfaceStyle = style
            }
        }
        .onChange(of: _selectedColorHex) { _ in
            UIApplication.topViewController()?.view.window?.tintColor = UIColor(Theme.tint)
        }
    }
}
