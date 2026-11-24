//
//  TweakPackage.swift
//  VexSign
//
//  The two parts of the tweak pipeline that do not need a signing session: which member of a `.deb`
//  is the payload, and where an injected item may be placed.
//
//  Both were `enum`s inside `TweakHandler`, which is an `ObservableObject` over a live signing
//  session — so the rules could only be exercised by driving the whole process. They are pure, they
//  are where the refusals live, and they are tested directly in `TweakPackageTests`.
//

import Foundation
import NimbleExtensions

/// Debian packages must identify one data archive. Unknown compression formats
/// are refused explicitly instead of producing a successful, empty injection.
enum DebianDataMember {
    enum SelectionError: LocalizedError, Equatable {
        case missing
        case multiple
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .missing:
                return .localized("This Debian package has no data archive to inject.")
            case .multiple:
                return .localized("This Debian package contains multiple data archives. VexSign cannot choose one safely.")
            case .unsupported(let name):
                return .localized("The Debian data archive %@ uses an unsupported format.", arguments: name)
            }
        }
    }

    static func select(from names: [String]) throws -> String {
        let candidates = names.filter { $0 == "data.tar" || $0.hasPrefix("data.tar.") }
        guard !candidates.isEmpty else { throw SelectionError.missing }
        guard candidates.count == 1, let name = candidates.first else { throw SelectionError.multiple }
        guard ArchiveFormat.debianDataMembers.contains(name) else {
            throw SelectionError.unsupported(name)
        }
        return name
    }

    /// How many extraction steps a member needs: a compressed payload produces the tar first, an
    /// uncompressed one is already the tar.
    static func extractionPasses(for memberName: String) -> Int {
        memberName == "data.tar" ? 1 : 2
    }

    /// Use the same extraction steps for preview and signing.
    static func extract(_ member: URL) throws -> URL {
        var result = member
        for _ in 0..<extractionPasses(for: member.lastPathComponent) {
            try extractFile(at: &result)
        }
        return result
    }
}

/// Never treat a conflicting framework or resource bundle as a successful placement.
/// FileManager.moveItem also refuses collisions that arise after the check.
enum TweakPlacement {
    struct Conflict: LocalizedError {
        let name: String
        var errorDescription: String? {
            .localized("Cannot add %@ because an item with that name already exists in the app.", arguments: name)
        }
    }

    static func move(_ source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw Conflict(name: destination.lastPathComponent)
        }
        try fileManager.moveItem(at: source, to: destination)
    }
}
