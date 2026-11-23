//
//  PackageContentClassifier.swift
//  VexSign
//
//  What a ZIP actually holds, read from its entry names instead of its suffix.
//
//  A `.zip` is the one extension that arrives for two different things: an app
//  someone zipped in Files, and a tweak bundle published by a repository. The
//  extension parser in `DomainContracts` can only see the suffix, so it sent
//  every `.zip` down the tweak path — which then reported "No tweaks found in
//  the archive" while the `.app` inside was never imported. Importing the same
//  bytes through the picker took the app path and worked, so the file was fine
//  and the routing was not.
//
//  This reads the archive's central directory (names only, nothing extracted)
//  and answers which path the file belongs on. It is deliberately separate from
//  `ArchiveSafetyValidator`: that type decides whether an archive is *safe* to
//  extract, this one decides where an archive is *routed*, and a rejected
//  archive still has to be routed somewhere before it can be refused with a
//  message that matches its contents.
//

import Foundation
import ZIPFoundation

enum PackageContentClassifier {
    enum Kind: Equatable {
        /// The archive carries an `.app` bundle: it belongs in the library.
        case application
        /// The archive carries a tweak payload (`DEBIAN/`, `Layout/`, a root `.dylib`).
        case tweak
        /// Neither shape was found, so the caller's existing message for that
        /// path is the honest answer.
        case unknown
    }

    /// A bundle is never described by more names than this before the first entry
    /// that identifies it; the cap keeps a hostile archive from making routing
    /// cost more than extraction would.
    static let scanLimit = 4096

    /// The verdict for the archive at `url`.
    ///
    /// Unreadable files are `.unknown` rather than an error: the caller already
    /// has a message for a file it cannot open, and a second one here would
    /// replace it with a routing failure that says nothing about the file.
    ///
    /// The archive-safety validator runs first. Reading a central directory is
    /// the step every extraction route starts with, and an archive that fails
    /// validation must not be routed anywhere: the path that owns the refusal
    /// message gets to say what is wrong with the file instead of this type
    /// guessing at a destination for it.
    static func classify(at url: URL, scanLimit limit: Int = PackageContentClassifier.scanLimit) -> Kind {
        do {
            try ArchiveSafetyValidator.validate(url)
        } catch {
            return .unknown
        }
        // Reopened rather than shared with the validator: a file that changed
        // between the two reads is a file nothing should be routed on.
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            return .unknown
        }
        var scanned = 0
        var carriesApplication = false
        var carriesTweak = false
        for entry in archive {
            scanned += 1
            if scanned > limit { break }
            let path = _normalized(entry.path)
            guard !path.isEmpty else { continue }

            let components = path.split(separator: "/", omittingEmptySubsequences: true).map { String($0) }
            guard let first = components.first else { continue }
            let lowered = first.lowercased()

            if lowered == "payload" {
                // `Payload/Name.app/…` is the IPA shape; anything else under
                // `Payload/` is not what a library import expects.
                if components.count > 1, components[1].hasSuffix(".app") { carriesApplication = true }
            } else if first.hasSuffix(".app") {
                // A repacked build with no `Payload/`: the bundle sits at the root.
                carriesApplication = true
            }

            if lowered == "debian" || lowered == "layout"
                || path.hasSuffix(".dylib")
                || path.hasPrefix("Library/MobileSubstrate/DynamicLibraries/") {
                carriesTweak = true
            }

            // One identifying entry is enough for the app shape: the rest of the
            // archive only repeats it, and stopping early keeps a large IPA cheap.
            if carriesApplication { return .application }
        }
        if carriesTweak { return .tweak }
        return .unknown
    }

    /// Strips the `./` and leading `/` that ZIP writers add inconsistently, so
    /// one naming convention cannot hide an app bundle from the classifier.
    private static func _normalized(_ path: String) -> String {
        var value = path
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst(1) }
        return value
    }
}
