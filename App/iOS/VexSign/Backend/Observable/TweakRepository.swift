//
//  TweakRepository.swift
//  VexSign
//
//  Metadata for user-added tweak feeds. A feed is not treated as verified just
//  because it is reachable; the same local trust rule as app repositories applies.
//

import Foundation

struct TweakRepository: Codable, Identifiable, Equatable {
	var id: UUID
	var name: String
	var url: URL
	var lastFetched: Date?
	var importedCount: Int

	init(id: UUID = UUID(), name: String, url: URL, lastFetched: Date? = nil, importedCount: Int = 0) {
		self.id = id
		self.name = name
		self.url = url
		self.lastFetched = lastFetched
		self.importedCount = importedCount
	}
}
