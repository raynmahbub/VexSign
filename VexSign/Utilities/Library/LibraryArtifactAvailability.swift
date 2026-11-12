//
//  LibraryArtifactAvailability.swift
//  VexSign
//
//  Whether a library row still has files behind it.
//
//  A library record and the bundle it points at are two different things, and nothing in the
//  app asked about the second one. A restore that brings back metadata without its artifacts, a
//  failed copy, a cleanup that removed a directory while the row survived — all leave a row that
//  renders exactly like a healthy one. The row is what the user sees, so the row is where the
//  answer has to come from.
//
//  The rule is decided from facts, not from the database: a record proves nothing about a file.
//  `Facts` is a value type and `state(for:)` is pure, so the rule is testable without a
//  filesystem; `facts(of:)` is the one place that reads the disk.
//

import Foundation
import NimbleExtensions

enum LibraryArtifactState: Equatable, Sendable {
    /// No read has happened yet. Never rendered as a problem.
    case unknown
    /// The bundle is on disk and complete enough to act on.
    case available
    /// The row points at a directory that is not there.
    case missing
    /// The directory exists but the bundle is not usable — no Info.plist, no executable, empty.
    case incomplete(String)

    var isUsable: Bool { self == .available }

    var title: String? {
        switch self {
        case .unknown, .available: nil
        case .missing: .localized("Files missing")
        case .incomplete: .localized("Incomplete files")
        }
    }

    var detail: String? {
        switch self {
        case .unknown, .available:
            return nil
        case .missing:
            return .localized("The files for this app are no longer on this device. The library entry is only metadata; import or download the app again to restore it.")
        case .incomplete(let reason):
            return reason
        }
    }
}

enum LibraryArtifactInspector {
    /// What the filesystem said, separated from the rule that judges it.
    struct Facts: Equatable, Sendable {
        var bundleDirectoryExists: Bool
        var infoPlistExists: Bool
        /// Executable name from the stored record, when one is known.
        var executableName: String?
        var executableExists: Bool
        /// Bytes in the bundle directory, when a size check ran.
        var byteCount: Int64?

        init(
            bundleDirectoryExists: Bool,
            infoPlistExists: Bool = false,
            executableName: String? = nil,
            executableExists: Bool = false,
            byteCount: Int64? = nil
        ) {
            self.bundleDirectoryExists = bundleDirectoryExists
            self.infoPlistExists = infoPlistExists
            self.executableName = executableName
            self.executableExists = executableExists
            self.byteCount = byteCount
        }
    }

    /// The verdict for one bundle.
    ///
    /// A missing directory is `missing` — the record outlived its files. Anything else is
    /// `incomplete`, because a directory that exists and cannot be launched is damaged rather
    /// than absent, and those two need different advice.
    static func state(for facts: Facts) -> LibraryArtifactState {
        guard facts.bundleDirectoryExists else { return .missing }
        guard facts.infoPlistExists else {
            return .incomplete(.localized("This app's Info.plist is missing, so it cannot be inspected or installed."))
        }
        if let name = facts.executableName, !name.isEmpty, !facts.executableExists {
            return .incomplete(.localized("This app's executable is missing from the bundle."))
        }
        if let bytes = facts.byteCount, bytes <= 0 {
            return .incomplete(.localized("This app's bundle is empty on disk."))
        }
        return .available
    }

    /// Adapter for `LibraryStatusStore.resolve`, which asks for the state of one bundle.
    static func read(_ bundleURL: URL) -> LibraryArtifactState {
        state(for: facts(of: bundleURL))
    }

    /// The one place that touches the disk.
    ///
    /// The size is only asked for when the cheaper checks pass, so a healthy row costs three
    /// `stat` calls and a damaged one costs fewer.
    static func facts(of bundleURL: URL, executableName: String? = nil) -> Facts {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Facts(bundleDirectoryExists: false)
        }

        let infoPlist = manager.fileExists(atPath: bundleURL.appendingPathComponent("Info.plist").path)
        guard infoPlist else {
            return Facts(bundleDirectoryExists: true, infoPlistExists: false)
        }

        let executable = executableName.flatMap { name -> Bool? in
            guard !name.isEmpty else { return nil }
            return manager.fileExists(atPath: bundleURL.appendingPathComponent(name).path)
        } ?? true

        guard executable else {
            return Facts(bundleDirectoryExists: true, infoPlistExists: true,
                         executableName: executableName, executableExists: false)
        }

        let bytes = directorySize(bundleURL)
        return Facts(bundleDirectoryExists: true, infoPlistExists: true,
                     executableName: executableName, executableExists: true, byteCount: bytes)
    }

    /// Recursive byte count, bounded so a large bundle cannot stall a library row.
    ///
    /// `nil` when the walk is too large or fails: an unknown size is better than a wrong one,
    /// and the state only uses a *known* zero as evidence of damage.
    private static func directorySize(_ url: URL, limit: Int = 50_000) -> Int64? {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var total: Int64 = 0
        var visited = 0
        for case let file as URL in enumerator {
            visited += 1
            if visited > limit { return nil }
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), // try? ok: a file that cannot be stat'ed is not evidence of damage
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
