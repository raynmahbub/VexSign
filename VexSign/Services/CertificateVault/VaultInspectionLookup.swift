//
//  VaultInspectionLookup.swift
//  VexSign
//
//  Service-side lookup of the read-only IPA inspection sidecar. Keeping the
//  Storage access here leaves SwiftUI free of persistence and file-I/O details.
//

import Foundation

enum VaultInspectionLookup {
    static func report(for app: LibraryAppRecord) -> AppBundleInspection? {
        guard let directory = Storage.shared.getAppDirectory(for: app) else { return nil }
        return ImportInspectionStore.read(from: directory)
    }
}
