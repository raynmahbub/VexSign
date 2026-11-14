//
//  Array+safe.swift
//  VexSign
//
//  Extracted from SourceAppsTableRepresentableView.swift for maintainability.
//

import Foundation

// MARK: - Array Extension
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
