//
//  LibraryDisplayPreferences.swift
//  VexSign
//

import Foundation
import UIKit
import NimbleExtensions

enum LibrarySort: String, CaseIterable {
	case manual
	case name
	case date
	case size

	var title: String {
		switch self {
		case .manual: .localized("Manual")
		case .name: .localized("Name")
		case .date: .localized("Date")
		case .size: .localized("Size")
		}
	}
}

enum LibraryDisplayPreferences {
	static let sortKey = "VexSign.library.sort"
	static let ascendingKey = "VexSign.library.sortAscending"

	static var sort: LibrarySort {
		get { LibrarySort(rawValue: UserDefaults.standard.string(forKey: sortKey) ?? "") ?? .manual }
		set { UserDefaults.standard.set(newValue.rawValue, forKey: sortKey) }
	}

	static var ascending: Bool {
		get {
			if UserDefaults.standard.object(forKey: ascendingKey) == nil { return true }
			return UserDefaults.standard.bool(forKey: ascendingKey)
		}
		set { UserDefaults.standard.set(newValue, forKey: ascendingKey) }
	}
}

// `InstalledApps.isInstalled` used to answer this with `canOpenURL("(identifier)://")`: wrong
// for every app that registers no URL scheme, and wrong again the moment the app is deleted.
// Installation state now comes from `LibraryStatusStore`, which asks the device.
