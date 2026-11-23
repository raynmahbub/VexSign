import SwiftUI
import NimbleExtensions

/// The compact trailing reveal uses one store-bound open-row identity in every
/// layout. Native leading workflow actions and context menus remain separate.
enum LibraryGridSwipePolicy {
    static func allowsAnimation(systemReduceMotion: Bool, requestedReduceMotion: Bool, animationsEnabled: Bool) -> Bool {
        animationsEnabled && !systemReduceMotion && !requestedReduceMotion
    }
    static func actionWidth(scaled: CGFloat) -> CGFloat {
        scaled.isFinite ? min(136, max(72, scaled)) : 82
    }
    static func isOpenAfterSwipe(horizontal: CGFloat, vertical: CGFloat, currentlyOpen: Bool) -> Bool {
        guard abs(horizontal) >= 45, abs(horizontal) > abs(vertical) * 1.3 else { return currentlyOpen }
        return horizontal < 0
    }
    static func revealedRow(after horizontal: CGFloat, vertical: CGFloat, row: String,
                            current: String?) -> String? {
        let open = isOpenAfterSwipe(horizontal: horizontal, vertical: vertical, currentlyOpen: current == row)
        if open { return row }
        return current == row ? nil : current
    }
}

struct LibraryGridSwipeDelete: ViewModifier {
    let enabled: Bool
    let rowID: String
    @Binding var revealedRowID: String?
    /// An embedding context may request less motion, never override the system's
    /// read-only Reduce Motion setting to enable animations against user choice.
    var reduceMotionRequested = false
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var appearance = AppearanceStore.shared
    @ScaledMetric(relativeTo: .body) private var actionWidth: CGFloat = 82
    @GestureState private var drag: CGFloat = 0

    private var isOpen: Bool { revealedRowID == rowID }
    private var actionAnimation: Animation? {
        LibraryGridSwipePolicy.allowsAnimation(systemReduceMotion: reduceMotion,
            requestedReduceMotion: reduceMotionRequested, animationsEnabled: appearance.animationsEnabled)
            ? .spring(response: 0.3, dampingFraction: 0.85) : nil
    }
    private var width: CGFloat { LibraryGridSwipePolicy.actionWidth(scaled: actionWidth) }
    private var reveal: CGFloat { min(width, max(0, (isOpen ? width : 0) - drag)) }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            // Reserve trailing space instead of sliding the icon/expiry off
            // the leading edge. The background cannot dictate the row's height,
            // so Delete remains compact in List rows and grid/icon cards alike.
            content
                .disabled(revealedRowID != nil)
                .allowsHitTesting(revealedRowID == nil)
                .overlay {
                    if revealedRowID != nil {
                        Button {
                            withAppAnimation(actionAnimation) { revealedRowID = nil }
                        } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(.localized("Close Delete action")))
                        .accessibilityIdentifier("library.closeDelete." + rowID)
                    }
                }
                .padding(.trailing, reveal)
                .background(alignment: .trailing) {
                    if isOpen || drag < 0 {
                        Button(role: .destructive) {
                            withAppAnimation(actionAnimation) { revealedRowID = nil }
                            onDelete()
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "trash")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .background(.red, in: Circle())
                                Text(.localized("Delete")).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: width)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(isOpen && drag == 0)
                        .accessibilityIdentifier("library.delete." + rowID)
                    }
                }
            .clipped()
            .contentShape(Rectangle())
            .appAnimation(drag == 0 ? actionAnimation : nil, value: isOpen)
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .updating($drag) { gesture, state, transaction in
                        guard abs(gesture.translation.width) > abs(gesture.translation.height) * 1.3 else { return }
                        transaction.animation = nil
                        state = gesture.translation.width
                    }
                    .onChanged { gesture in
                        if gesture.translation.width < -18, abs(gesture.translation.width) > abs(gesture.translation.height) * 1.3,
                           let current = revealedRowID, current != rowID { revealedRowID = nil }
                    }
                    .onEnded { gesture in
                        let next = LibraryGridSwipePolicy.revealedRow(after: gesture.translation.width,
                            vertical: gesture.translation.height, row: rowID, current: revealedRowID)
                        guard next != revealedRowID else { return }
                        NBHaptic.selection()
                        withAppAnimation(actionAnimation) { revealedRowID = next }
                    }
            )
            .accessibilityAction(named: Text(.localized("Delete"))) { onDelete() }
            .accessibilityAction(named: Text(.localized("Close"))) { revealedRowID = nil }
            .onDisappear { if isOpen { revealedRowID = nil } }
        } else {
            content.onAppear { if isOpen { revealedRowID = nil } }
        }
    }
}
