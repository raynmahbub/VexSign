import Foundation

/// Managed identities live outside shared Documents. User-selected originals
/// are never removed. UUID-directory migration preserves collisions privately.
enum ProtectedCertificateFiles {
    private static let lock = NSLock()

    static func directory(legacy: URL, destination: URL,
                          migration: (URL, URL) throws -> Void = { try migrate(legacy: $0, destination: $1) },
                          report: (CredentialMigrationIssue?) -> Void = {
                              CredentialMigrationDiagnostics.report(source: .certificateFiles, issue: $0)
                          }) -> URL {
        lock.lock()
        defer { lock.unlock() }
        do {
            try migration(legacy, destination)
            report(nil)
            return destination
        } catch {
            report(CredentialMigrationIssue.classify(error))
            // Access failure may mean protected data or permissions, not corruption.
            // Do not remove remaining legacy files or hide the fallback from users.
            return FileManager.default.fileExists(atPath: legacy.path) ? legacy : destination
        }
    }

    static func migrate(legacy: URL, destination: URL, beforeMove: (URL, URL) throws -> Void = { _, _ in }) throws {
        let fm = FileManager.default
        var destination = destination
        try fm.createDirectory(at: destination, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
        if fm.fileExists(atPath: legacy.path) {
            for child in try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let target = destination.appendingPathComponent(child.lastPathComponent)
                // Children can be plain .p12 files or UUID directories. Protect
                // either form before moving it into private storage.
                try protectItem(child)
                // Preserve any older conflicting copy, but never replace the
                // currently registered identity with it.
                let output = fm.fileExists(atPath: target.path)
                    ? destination.appendingPathComponent("legacy-\(UUID().uuidString)") : target
                try beforeMove(child, output)
                try fm.moveItem(at: child, to: output)
            }
            try fm.removeItem(at: legacy) // Empty only; failed moves throw above.
        }
        try applyProtectionAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                       .posixPermissions: 0o700], at: destination.path)
    }

    /// Applies a protection class where the volume has one, and the permissions either way.
    ///
    /// Data protection is an iOS *device* filesystem feature. The simulator has no protection
    /// classes, so `setAttributes` rejects `.protectionKey` there with ENOTSUP /
    /// NSFeatureUnsupportedError. Treating that as a migration failure aborted the move before
    /// any file was copied, which is why `VexSignTests` failed on the simulator while the same
    /// code worked on a device (#136). Only that specific refusal is tolerated: a real
    /// permission or I/O error still propagates, so a device never silently loses protection.
    static func applyProtectionAttributes(
        _ attributes: [FileAttributeKey: Any],
        at path: String,
        setAttributes: ([FileAttributeKey: Any], String) throws -> Void = {
            try FileManager.default.setAttributes($0, ofItemAtPath: $1)
        }
    ) throws {
        do {
            try setAttributes(attributes, path)
        } catch {
            guard isDataProtectionUnsupported(error), attributes[.protectionKey] != nil else { throw error }
            var withoutProtection = attributes
            withoutProtection.removeValue(forKey: .protectionKey)
            guard !withoutProtection.isEmpty else { return }
            try setAttributes(withoutProtection, path)
        }
    }

    /// True only for "this volume does not implement protection classes".
    static func isDataProtectionUnsupported(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFeatureUnsupportedError { return true }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(ENOTSUP) || nsError.code == Int(EOPNOTSUPP) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isDataProtectionUnsupported(underlying)
        }
        return false
    }

    /// Protects an item and its descendants with a single directory walk.
    static func protectItem(_ url: URL) throws {
        try protect(url)
    }

    /// A file is protected directly; directories are enumerated exactly once.
    /// The injectable setter is also used to verify traversal and error handling.
    static func protect(
        _ root: URL,
        setAttributes: ([FileAttributeKey: Any], String) throws -> Void = {
            try FileManager.default.setAttributes($0, ofItemAtPath: $1)
        }
    ) throws {
        let fm = FileManager.default
        let rootInfo = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        var urls = [root]
        if rootInfo.isDirectory == true {
            var enumerationError: Error?
            guard let children = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                               errorHandler: { _, error in
                                                   enumerationError = error
                                                   return false
                                               }) else { throw CocoaError(.fileReadUnknown) }
            while let url = children.nextObject() as? URL { urls.append(url) }
            if let enumerationError { throw enumerationError }
        }
        for url in urls {
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            try applyProtectionAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                           .posixPermissions: info.isDirectory == true ? 0o700 : 0o600],
                                          at: url.path, setAttributes: setAttributes)
        }
    }

}
