import Foundation
import NimbleExtensions

extension IPAChange {
	var title: String {
		switch kind {
		case .added: .localized("Added")
		case .modified: .localized("Edited")
		case .removed: .localized("Removed")
		}
	}

	/// Symbol shown next to the change in the "what changed" list.
	var symbol: String {
		switch kind {
		case .added: "plus.circle.fill"
		case .modified: "pencil.circle.fill"
		case .removed: "minus.circle.fill"
		}
	}
}
