//
//  WebThemeMotion.swift
//  VexSign
//
//  Small native motion treatment for the optional Flare presentation.
//  It uses no website JavaScript or assets and respects Reduce Motion plus the
//  existing Flare Touch Animations preference.
//
//  The modifier observes the shared `AppearanceStore` (injected through the
//  environment at the app root) so a theme switch updates it immediately
//  without re-reading UserDefaults from every view.
//

import SwiftUI

struct VexSignWebMotionModifier: ViewModifier {
    @ObservedObject private var appearance = AppearanceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlightPhase = false

    private var isEnabled: Bool {
        appearance.isFlare && appearance.animationsEnabled && !reduceMotion
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isEnabled {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Theme.websiteAccent.opacity(0.72), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 220, height: 2)
                        .blur(radius: 0.4)
                        .offset(x: highlightPhase ? proxy.size.width : -240)
                        .animation(
                            .easeInOut(duration: 2.8).repeatForever(autoreverses: false),
                            value: highlightPhase
                        )
                    }
                    .frame(height: 2)
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onAppear { highlightPhase = true }
                }
            }
    }
}

extension View {
    func vexSignWebMotion() -> some View {
        modifier(VexSignWebMotionModifier())
    }
}
