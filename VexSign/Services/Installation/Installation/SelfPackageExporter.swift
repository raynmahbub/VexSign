//
//  SelfPackageExporter.swift
//  VexSign
//
//  Packages the running build as an IPA.
//
//  Reinstalling VexSign on a device that trusts it — a TrollStore install, or a
//  copy someone already signed — needs the bundle and nothing else. Requiring a
//  certificate and a profile for that was a rule borrowed from installing other
//  apps: the in-place update path refuses a copy that is not signed, correctly,
//  but a TrollStore device never needed the signature in the first place.
//
//  This uses the same `AppArchiver` the installer and the Web Manager already
//  use to turn an `.app` into an IPA, so the output is the shape those routes
//  produce rather than a second implementation of it.
//

import Foundation
import NimbleExtensions

enum SelfPackageExporter {
    enum Failure: LocalizedError {
        /// The process is not running from a real `.app` bundle, as in a
        /// LiveContainer guest whose host owns the bundle on disk.
        case notAnApplicationBundle
        case unreadableBundle(String)

        var errorDescription: String? {
            switch self {
            case .notAnApplicationBundle:
                return .localized("This build does not run from its own app bundle, so there is nothing to package. Export the host build instead.")
            case .unreadableBundle(let name):
                return .localized("This build could not be packaged: %@ could not be read.", arguments: name)
            }
        }
    }

    /// The name the exported IPA is saved under.
    static var fileName: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let suffix = [version, build].compactMap { $0 }.joined(separator: "-")
        return suffix.isEmpty ? "VexSign.ipa" : "VexSign-\(suffix).ipa"
    }

    /// Whether packaging this process makes sense at all.
    ///
    /// A guest build runs from the host's bundle, so packaging it would export
    /// the host — a different app — under VexSign's name.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && !(Bundle.main.object(forInfoDictionaryKey: "VexSignEmbeddedGuest") as? Bool ?? false)
    }

    /// Writes this build as an IPA into `directory` and returns its URL.
    ///
    /// Declared `nonisolated ... async` on purpose: SE-0338 puts the body on the
    /// generic executor even when the caller is on the main actor, so the copy and
    /// the compression do not stall the UI, and the app does not need another
    /// unowned `Task.detached` for it.
    nonisolated static func export(
        to directory: URL,
        compression: ArchiveCompression = .defaultCompression
    ) async throws -> URL {
        let bundle = Bundle.main.bundleURL
        guard isAvailable else { throw Failure.notAnApplicationBundle }
        let fm = FileManager.default
        try fm.createDirectoryIfNeeded(at: directory)
        let destination = directory.appendingPathComponent(fileName)
        do {
            try AppArchiver.archive(appDir: bundle, to: destination, compression: compression)
        } catch {
            // The cause is carried into the sentence: a full disk and an
            // unreadable bundle need different fixes, and "could not be read"
            // alone would hide which one happened.
            throw Failure.unreadableBundle("\(bundle.lastPathComponent) — \(error.localizedDescription)")
        }
        return destination
    }

    /// Where the export is written: the app's own Documents directory, so the file
    /// survives the sheet that produced it and stays visible in Files.
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Exports", isDirectory: true)
    }
}
