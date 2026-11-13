//
//  HomeFlareComponents.swift
//  VexSign
//
//  Flare-inspired presentation tokens and reusable tile/row components for HomeView.
//

import SwiftUI

enum FlarePalette {
    private static var visualTheme: VexSignVisualTheme {
        AppearanceStore.snapshot().visualTheme
    }

    private static var isBase: Bool { !visualTheme.isLegacyPresentation }
    private static var isWeb: Bool { visualTheme == .flare }

    static var background: Color {
        isBase ? Theme.background : Color(red: 0.025, green: 0.022, blue: 0.045)
    }
    static var card: Color {
        isBase ? Theme.card : (isWeb ? Theme.card : Color(red: 0.065, green: 0.065, blue: 0.095))
    }
    static var border: Color {
        isBase ? Theme.separator : (isWeb ? Theme.separator : Color.white.opacity(0.10))
    }
    static var grid: Color {
        if isBase { return .clear }
        if isWeb { return Theme.separator.opacity(0.8) }
        return Color(red: 0.42, green: 0.025, blue: 0.19).opacity(0.52)
    }
    static var muted: Color {
        isBase ? Theme.secondary : Color(red: 0.49, green: 0.47, blue: 0.55)
    }
    static var text: Color {
        isBase ? Theme.primary : .white
    }
    static var pink: Color {
        isBase ? Theme.tint : (isWeb ? Theme.websiteAccent : Color(red: 1.0, green: 0.12, blue: 0.34))
    }
    static var purple: Color {
        isWeb ? Theme.websiteAccentSecondary : Color(red: 0.62, green: 0.20, blue: 1.0)
    }
    static var green: Color { Color(red: 0.03, green: 0.76, blue: 0.50) }
}

struct FlareGridBackground: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 71

            var x: CGFloat = 0
            while x <= size.width + spacing {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }

            var y: CGFloat = 0
            while y <= size.height + spacing {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }

            context.stroke(path, with: .color(FlarePalette.grid), lineWidth: 0.8)
        }
        .background(FlarePalette.background)
        // Purely decorative — keep it out of VoiceOver and Reduce Motion.
        .accessibilityHidden(true)
    }
}

struct HomeIconTile: View {
    let systemImage: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(tint.opacity(0.15))
                .frame(width: size, height: size)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

struct HomeMetricCard: View {
    let icon: String
    let value: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(height: 30)

                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlarePalette.text)
                    .monospacedDigit()

                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(FlarePalette.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(FlarePalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(FlarePalette.border, lineWidth: 1)
            }
        }
        .buttonStyle(VexSignFlareButtonStyle())
        .accessibilityLabel(Text("\(value) \(title)"))
    }
}

struct HomeFeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 16) {
            HomeIconTile(systemImage: icon, tint: tint, size: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlarePalette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(FlarePalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(FlarePalette.muted)
        }
        .padding(.horizontal, 17)
        .frame(minHeight: 82)
        .background(FlarePalette.card, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(FlarePalette.border, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}
