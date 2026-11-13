//
//  ArchiveCompression.swift
//  VexSign
//

import Foundation
import NimbleExtensions
import ZIPFoundation

enum ArchiveCompression: Int, CaseIterable, Equatable, Sendable {
	case noCompression = 0
	case bestSpeed = 1
	case defaultCompression = 2
	case bestCompression = 3

	var label: String {
		switch self {
		case .noCompression: .localized("None")
		case .bestSpeed: .localized("Speed")
		case .defaultCompression: .localized("Default")
		case .bestCompression: .localized("Best")
		}
	}

	var compressionMethod: CompressionMethod {
		self == .noCompression ? .none : .deflate
	}
}
