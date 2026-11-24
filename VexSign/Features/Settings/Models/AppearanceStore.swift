//
//  AppearanceStore.swift
//  VexSign
//
//  The single observable source of truth for presentation preferences:
//  visual theme, font family, font scale and Flare touch animations.
//
//  Previously every consumer read `UserDefaults` (or `@AppStorage`) directly,
//  so several views could hold stale values and theme switches lagged behind.
//  The store is injected through the SwiftUI environment; mutations publish
//  immediately to every observer while still persisting under the same keys,
//  so existing user preferences and backups keep working.
//
//  `snapshot()` is a lock-free, thread-safe read for non-reactive call sites
//  (e.g. `Theme`'s static tokens) — it reads UserDefaults exactly like the
//  previous implementation did.
//

import SwiftUI

@MainActor
final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()

    @Published private(set) var visualTheme: VexSignVisualTheme
    @Published private(set) var fontFamily: VexSignFontFamily
    @Published private(set) var fontScale: Double
    @Published private(set) var animationsEnabled: Bool

    private init() {
        let defaults = UserDefaults.standard
        let themeRaw = defaults.string(forKey: VexSignStylePreferences.visualThemeKey)
            ?? VexSignVisualTheme.system.rawValue
        let fontRaw = defaults.string(forKey: VexSignStylePreferences.fontFamilyKey)
            ?? VexSignFontFamily.system.rawValue
        let storedScale = defaults.double(forKey: VexSignStylePreferences.fontScaleKey)
        let storedAnimations = defaults.object(forKey: VexSignStylePreferences.flareAnimationsKey) as? Bool

        self.visualTheme = VexSignVisualTheme(rawValue: themeRaw) ?? .system
        self.fontFamily = VexSignFontFamily(rawValue: fontRaw) ?? .system
        self.fontScale = storedScale == 0 ? 1.0 : min(max(storedScale, 0.85), 1.25)
        self.animationsEnabled = storedAnimations ?? true
    }

    // MARK: - Mutations (persist + publish)

    func setVisualTheme(_ theme: VexSignVisualTheme) {
        guard theme != visualTheme else { return }
        visualTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: VexSignStylePreferences.visualThemeKey)
    }

    func setFontFamily(_ family: VexSignFontFamily) {
        guard family != fontFamily else { return }
        fontFamily = family
        UserDefaults.standard.set(family.rawValue, forKey: VexSignStylePreferences.fontFamilyKey)
    }

    func setFontScale(_ scale: Double) {
        let clamped = min(max(scale, 0.85), 1.25)
        guard clamped != fontScale else { return }
        fontScale = clamped
        UserDefaults.standard.set(clamped, forKey: VexSignStylePreferences.fontScaleKey)
    }

    func setAnimationsEnabled(_ enabled: Bool) {
        guard enabled != animationsEnabled else { return }
        animationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: VexSignStylePreferences.flareAnimationsKey)
    }

    // MARK: - Derived

    var isFlare: Bool { visualTheme == .flare }
    var isLuna: Bool { visualTheme == .luna }

    /// Presets define their interface scheme; System follows the user preference.
    var prefersDarkSurfaces: Bool { visualTheme.preferredColorScheme == .dark }

    var font: Font {
        VexSignStylePreferences.font(familyRawValue: fontFamily.rawValue, scale: fontScale)
    }

    // MARK: - Snapshot (thread-safe, non-reactive)

    struct Snapshot {
        let visualTheme: VexSignVisualTheme
        let fontFamily: VexSignFontFamily
        let fontScale: Double
        let animationsEnabled: Bool

        var isFlare: Bool { visualTheme == .flare }
        var isLuna: Bool { visualTheme == .luna }
        var prefersDarkSurfaces: Bool { visualTheme.preferredColorScheme == .dark }
    }

    /// A non-reactive read of the persisted values. Safe from any thread;
    /// identical to the pre-store behaviour where `Theme` read UserDefaults
    /// directly on every access.
    nonisolated static func snapshot() -> Snapshot {
        let defaults = UserDefaults.standard
        let themeRaw = defaults.string(forKey: VexSignStylePreferences.visualThemeKey)
            ?? VexSignVisualTheme.system.rawValue
        let fontRaw = defaults.string(forKey: VexSignStylePreferences.fontFamilyKey)
            ?? VexSignFontFamily.system.rawValue
        let storedScale = defaults.double(forKey: VexSignStylePreferences.fontScaleKey)
        return Snapshot(
            visualTheme: VexSignVisualTheme(rawValue: themeRaw) ?? .system,
            fontFamily: VexSignFontFamily(rawValue: fontRaw) ?? .system,
            fontScale: storedScale == 0 ? 1.0 : min(max(storedScale, 0.85), 1.25),
            animationsEnabled: defaults.object(forKey: VexSignStylePreferences.flareAnimationsKey) as? Bool ?? true
        )
    }
}
