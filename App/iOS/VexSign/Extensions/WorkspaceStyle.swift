import SwiftUI

/// Scale the inherited body font with Dynamic Type; technical views may still
/// explicitly use monospaced styles without forcing that font across the app.
struct VexWorkspaceTypography: ViewModifier {
    @ObservedObject private var appearance = AppearanceStore.shared
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17

    func body(content: Content) -> some View {
        content.environment(\.font, .system(
            size: bodySize * appearance.fontScale,
            design: appearance.fontFamily.design
        ))
    }
}

/// Readable content cards stay opaque. Glass belongs on navigation/actions,
/// rather than behind logs, forms or dense app information.
struct WorkspaceCard<Content: View>: View {
    @ObservedObject private var appearance = AppearanceStore.shared
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.Spacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.separator, lineWidth: contrast == .increased ? 1.5 : 0.5)
            }
    }
}

/// Use native glass only for a compact navigation action, with an opaque fallback.
struct VexToolbarActionStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency, contrast != .increased {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}


struct VexWorkspaceAccessibility: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}
