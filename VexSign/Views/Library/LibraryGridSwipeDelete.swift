import SwiftUI
import NimbleExtensions

/// Grid cards are not List rows, so SwiftUI's native swipeActions do not apply.
/// Reveal an explicit Delete button; the caller still owns the confirmation.
enum LibraryGridSwipePolicy {
    static func isOpenAfterSwipe(horizontal: CGFloat, vertical: CGFloat, currentlyOpen: Bool) -> Bool {
        guard abs(horizontal) >= 45, abs(horizontal) > abs(vertical) * 1.3 else { return currentlyOpen }
        return horizontal < 0
    }
}

struct LibraryGridSwipeDelete: ViewModifier {
    let enabled: Bool
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var appearance = AppearanceStore.shared
    @State private var isOpen = false
    private let actionWidth: CGFloat = 78

    private var actionAnimation: Animation? {
        reduceMotion || !appearance.animationsEnabled ? nil : .easeInOut(duration: 0.2)
    }

    init(enabled: Bool, onDelete: @escaping () -> Void) {
        self.enabled = enabled
        self.onDelete = onDelete
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            ZStack(alignment: .trailing) {
                if isOpen {
                    Button(role: .destructive) {
                        withAnimation(actionAnimation) { isOpen = false }
                        onDelete()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text(.localized("Delete"))
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.white)
                        .frame(width: actionWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color.red)
                }
                content
                    .offset(x: isOpen ? -actionWidth : 0)
            }
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onEnded { gesture in
                    let next = LibraryGridSwipePolicy.isOpenAfterSwipe(
                        horizontal: gesture.translation.width,
                        vertical: gesture.translation.height,
                        currentlyOpen: isOpen
                    )
                    guard next != isOpen else { return }
                    NBHaptic.selection()
                    if next { InterfaceFeedback.selection() }
                    withAnimation(actionAnimation) { isOpen = next }
                }
            )
            .accessibilityAction(named: Text(.localized("Delete"))) { onDelete() }
        } else {
            content.onAppear { isOpen = false }
        }
    }
}
