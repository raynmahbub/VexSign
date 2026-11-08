import Foundation

/// Pairing credentials must not be exposed through Documents/file sharing.
/// Migration moves (never deletes) the legacy file only after protection succeeds.
public enum PairingFileStorage {
    private static let lock = NSLock()

    public static func path() -> String {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let legacy = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pairingFile.plist")
        let destination = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Private", isDirectory: true).appendingPathComponent("pairingFile.plist")
        do { return try migrate(legacy: legacy, destination: destination).path }
        catch {
            // Preserve access to existing credentials on a locked/unwritable device.
            // No credential, file contents or private path is printed.
            return fm.fileExists(atPath: destination.path) ? destination.path : legacy.path
        }
    }

    @discardableResult
    public static func migrate(legacy: URL, destination: URL) throws -> URL {
        let fm = FileManager.default
        var directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let protection: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o600]
        if fm.fileExists(atPath: legacy.path) {
            try fm.setAttributes(protection, ofItemAtPath: legacy.path)
            // Never overwrite a newer imported pairing file. Preserve the older
            // record privately as well, rather than leaving it in shared Documents.
            let target = fm.fileExists(atPath: destination.path)
                ? directory.appendingPathComponent("legacy-\(UUID().uuidString).plist") : destination
            try fm.moveItem(at: legacy, to: target)
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.setAttributes(protection, ofItemAtPath: destination.path)
        }
        return destination
    }
}
