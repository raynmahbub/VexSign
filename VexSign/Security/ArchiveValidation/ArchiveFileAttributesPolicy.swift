//
//  ArchiveFileAttributesPolicy.swift
//  VexSign
//
//  ZIP central-directory entries carry POSIX mode bits supplied by whoever
//  packed the file. Inside an IPA that mode is a hint (an executable Mach-O needs
//  its execute bit), not a request to give the extracted file privileges the
//  app never asked for. Applying it verbatim could create setuid, setgid or sticky
//  files in the app's writable container, and world-writable bundle contents let
//  another process in the same app group replace code before it is signed.
//
//  The policy keeps only the ordinary rwx bits and caps them: directories at
//  0o700–0o755 and files at 0o600–0o755. Execute stays available for bundled
//  tools, while group/other write and all special bits are removed. It is pure
//  so the same rule can be tested without constructing a malicious archive.
//

import Foundation

enum ArchiveFileAttributesPolicy {
    /// Highest mode an extracted entry may receive, for files and directories.
    static let maximumPermissions: Int = 0o755

    /// Returns metadata safe to apply to a newly extracted entry.
    static func sanitized(_ attributes: [FileAttributeKey: Any], isDirectory: Bool) -> [FileAttributeKey: Any] {
        var result = attributes
        let declared = (attributes[.posixPermissions] as? NSNumber)?.intValue
            ?? (isDirectory ? 0o755 : 0o644)
        // `0o7777` discards the file-type bits and the setuid/setgid/sticky bits
        // before the rwx cap; a negative or nonsensical value falls back to safe.
        let ordinary = declared >= 0 ? declared & 0o777 : (isDirectory ? 0o755 : 0o644)
        // A bitwise cap, not `min`: 0o764 must become 0o744, not 0o755.
        result[.posixPermissions] = NSNumber(value: ordinary & maximumPermissions)
        return result
    }
}
