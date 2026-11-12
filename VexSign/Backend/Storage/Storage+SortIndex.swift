//
//  Storage+SortIndex.swift
//  VexSign
//
//  Ordering values for the library lists.
//

import CoreData

extension Storage {
	/// The next ordering value below everything already stored for `entity`, so a new row
	/// lands at the top of its list.
	///
	/// The first call on a context seeds a counter from the store; every call after that
	/// decrements it. Reading the lowest row on every insert was not enough under
	/// concurrent imports: a fetch that fails is swallowed by `try?` and falls back to 1,
	/// so two inserts could both be given 0 and collapse into one position. A counter
	/// cannot do that, and it removes a fetch from every insert.
	///
	/// Writes are serialised on the write context (see `write(_:)`), which is the only
	/// queue that reaches the counter, so it needs no lock of its own. `userInfo` belongs
	/// to the context, so a fresh context seeds itself again.
	func nextSortIndex(in context: NSManagedObjectContext, entity: String) -> Int32 {
		let key = "vexsign.nextSortIndex.\(entity)"
		if let next = context.userInfo[key] as? Int32 {
			let value = next - 1
			context.userInfo[key] = value
			return value
		}

		let request = NSFetchRequest<NSManagedObject>(entityName: entity)
		request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
		request.fetchLimit = 1
		let lowest = (try? context.fetch(request))?.first?.value(forKey: "sortIndex") as? Int32 ?? 1

		let value = lowest - 1
		context.userInfo[key] = value
		return value
	}
}