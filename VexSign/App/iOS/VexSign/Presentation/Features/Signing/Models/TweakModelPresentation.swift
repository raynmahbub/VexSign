import Foundation
import NimbleExtensions

extension TweakVersion {
	var displaySummary: String {
		switch components.count {
		case 0: 	return ""
		case 1: 	return components[0].fileName
		default: 	return String.localized("%lld files", arguments: components.count)
		}
	}
}

// MARK: - Model extension: sorting
extension ManagedTweak: SortableItem {
	var sortName: String { name }
	var sortDate: Date { dateAdded }
	var sortSize: Int64 { activeVersion?.fileSize ?? 0 }
}
