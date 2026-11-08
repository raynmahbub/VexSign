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
                try protect(child)
                // Preserve any older conflicting copy, but never replace the
                // currently registered identity with it.
                let output = fm.fileExists(atPath: target.path)
                    ? destination.appendingPathComponent("legacy-\(UUID().uuidString)") : target
                try beforeMove(child, output)
                try fm.moveItem(at: child, to: output)
            }
            try fm.removeItem(at: legacy) // Empty only; failed moves throw above.
        }
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                              .posixPermissions: 0o700], ofItemAtPath: destination.path)
    }

    static func protect(_ root: URL) throws {
        let fm = FileManager.default
        let rootInfo = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        var enumerationError: Error?
        let children = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                     errorHandler: { _, error in
                                         enumerationError = error
                                         return false
                                     })
        if rootInfo.isDirectory == true && children == nil { throw CocoaError(.fileReadUnknown) }
        var urls = [root]
        while let url = children?.nextObject() as? URL { urls.append(url) }
        if let enumerationError { throw enumerationError }
        for url in urls {
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                  .posixPermissions: info.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: url.path)
        }
    }
}
