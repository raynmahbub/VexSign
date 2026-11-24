import SwiftUI
import NimbleExtensions

// MARK: - Banner

private struct UndoableRemovalBanner: ViewModifier {
	@State private var _current: UndoableRemoval?

	func body(content: Content) -> some View {
		content
			.safeAreaInset(edge: .bottom) {
				if let removal = _current {
					HStack {
						Text(String.localized("Removed %@", arguments: removal.title))
							.font(.subheadline)
							.lineLimit(1)
						Spacer()
						Button(.localized("Undo")) {
							if UndoableRemoval.undo(removal) { _current = nil }
						}
						.fontWeight(.semibold)
					}
					.padding(.horizontal, 16)
					.padding(.vertical, 12)
					.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
					.padding(.horizontal, 16)
					.padding(.bottom, 8)
					.transition(.move(edge: .bottom).combined(with: .opacity))
				}
			}
			.appAnimation(.snappy, value: _current?.id)
			.onReceive(NotificationCenter.default.publisher(for: UndoableRemoval.announced)) { note in
				guard let removal = note.userInfo?["removal"] as? UndoableRemoval else { return }
				// A newer removal replaces the offer on screen; the older one keeps its own
				// countdown and becomes permanent when that ends.
				_current = removal
			}
			.onReceive(NotificationCenter.default.publisher(for: UndoableRemoval.resolved)) { note in
				guard let id = note.userInfo?["id"] as? UUID, _current?.id == id else { return }
				_current = nil
			}
	}
}

extension View {
	/// Shows "Removed … Undo" at the bottom of this screen after an undoable removal.
	func undoableRemovalBanner() -> some View {
		modifier(UndoableRemovalBanner())
	}
}
