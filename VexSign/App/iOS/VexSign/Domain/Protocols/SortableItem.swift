import Foundation

protocol SortableItem {
	var sortName: String { get }
	var sortDate: Date { get }
	var sortSize: Int64 { get }
}
