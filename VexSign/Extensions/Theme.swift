//
//  Theme.swift
//  VexSign — central design tokens (single source of truth)
//  All surfaces, spacing, radius and semantic colors live here.
//

import SwiftUI
import NimbleViews

enum Theme {
    private static var visualTheme: VexSignVisualTheme {
        AppearanceStore.snapshot().visualTheme
    }

    private static var isLuna: Bool { visualTheme == .luna }
    private static var isFlareWeb: Bool { visualTheme == .flare }

    // MARK: - Website-inspired palette
    // These are original native tokens, not copied website CSS or assets.
    static var websiteAccent: Color { Color(red: 0.47, green: 0.39, blue: 1.0) }
    static var websiteAccentSecondary: Color { Color(red: 0.17, green: 0.78, blue: 0.95) }
    static var websiteGlow: Color { websiteAccent.opacity(0.25) }

    // MARK: - Surfaces
    static var background: Color { background(for: visualTheme) }
    static func background(for theme: VexSignVisualTheme) -> Color {
        switch theme {
        case .midnightViolet: return Color(red: 0.045, green: 0.041, blue: 0.065)
        case .graphite: return Color(red: 0.065, green: 0.069, blue: 0.078)
        case .paper: return Color(red: 0.965, green: 0.953, blue: 0.925)
        case .oled: return .black
        default: break
        }
        if theme == .flare { return Color(red: 0.035, green: 0.045, blue: 0.10) }
        return theme == .luna ? Color(red: 0.055, green: 0.065, blue: 0.14) : Color(uiColor: .systemGroupedBackground)
    }
    static var card: Color { card(for: visualTheme) }
    static func card(for theme: VexSignVisualTheme) -> Color {
        switch theme {
        case .midnightViolet: return Color(red: 0.090, green: 0.082, blue: 0.116)
        case .graphite: return Color(red: 0.112, green: 0.118, blue: 0.133)
        case .paper: return Color(red: 0.998, green: 0.992, blue: 0.973)
        case .oled: return Color(white: 0.065)
        default: break
        }
        if theme == .flare { return Color(red: 0.075, green: 0.09, blue: 0.17) }
        return theme == .luna ? Color(red: 0.105, green: 0.115, blue: 0.22) : Color(uiColor: .secondarySystemGroupedBackground)
    }
    static var cardElevated: Color {
        if !visualTheme.isLegacyPresentation && visualTheme != .system { return card }
        if isFlareWeb { return Color(red: 0.105, green: 0.125, blue: 0.23) }
        return isLuna ? Color(red: 0.14, green: 0.145, blue: 0.28) : Color(uiColor: .secondarySystemGroupedBackground)
    }
    static var separator: Color {
        if isFlareWeb { return Color(red: 0.30, green: 0.35, blue: 0.62).opacity(0.34) }
        return isLuna ? Color.white.opacity(0.12) : Color(uiColor: .separator).opacity(0.55)
    }
    static var quaternary: Color {
        if isFlareWeb { return Color(red: 0.15, green: 0.18, blue: 0.32) }
        return isLuna ? Color(red: 0.19, green: 0.19, blue: 0.34) : Color(uiColor: .quaternarySystemFill)
    }

    // MARK: - Text
    static var primary: Color { .primary }
    static var secondary: Color { .secondary }
    static var tertiary: Color { Color(uiColor: .tertiaryLabel) }

    // MARK: - Tint
    static var tint: Color { isFlareWeb ? websiteAccent : Color.userTint }
    static var tintDeep: Color { isFlareWeb ? Color(red: 0.31, green: 0.25, blue: 0.76) : Color.userTintDeep }
    static var tintSoft: Color { tint.opacity(0.12) }

    // MARK: - Metrics
    enum Radius {
        static let large: CGFloat = NBRadius.large // 28 on iOS26, 12 otherwise
        static let card: CGFloat = 18
        static let cardWide: CGFloat = 22
        static let rail: CGFloat = 20
        static let hero: CGFloat = 30
        static let mark: CGFloat = 14
        static let medium: CGFloat = 12
        static let pill: CGFloat = 999
    }
    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let cardPadding: CGFloat = 16
        static let section: CGFloat = 24
        static let large: CGFloat = 32
        static let row: CGFloat = NBSpacing.row
    }

    // MARK: - Shadows
    static func cardShadow(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.20) : Color.black.opacity(0.06)
    }

    // MARK: - Gradients
    static var appStoreGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.05, green: 0.38, blue: 0.96), Color(red: 0.32, green: 0.60, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var filesGradient: LinearGradient {
        LinearGradient(colors: [Color.userTint.opacity(0.22), Color.userTintDeep.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Shared accent treatment used by cards, headers and touch feedback. It is
    /// intentionally translucent so it remains legible in both appearances.
    static var flareGradient: LinearGradient {
        LinearGradient(
            colors: [tint.opacity(0.28), tintDeep.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var flareShadow: Color {
        tint.opacity(0.20)
    }
}
