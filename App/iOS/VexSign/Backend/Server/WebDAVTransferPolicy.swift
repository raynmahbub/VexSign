import Foundation

/// Prevent an overwrite from deleting the source or the WebDAV inbox itself.
enum WebDAVTransferPolicy {
    static func permits(source: URL, destination: URL, inbox: URL) -> Bool {
        guard let root = components(inbox),
              let from = components(source),
              let to = components(destination) else { return false }

        func contains(_ parent: [String], _ child: [String]) -> Bool {
            child.count >= parent.count && Array(child.prefix(parent.count)) == parent
        }
        guard contains(root, from), contains(root, to), from != root, to != root else { return false }
        return !contains(from, to) && !contains(to, from)
    }

    /// Resolve the longest existing prefix before restoring a missing suffix.
    /// Resolving a full URL can leave an ancestor symlink unresolved when the
    /// final destination does not exist yet (for example, `alias/new-file`).
    private static func components(_ url: URL) -> [String]? {
        guard url.isFileURL else { return nil }

        let fileManager = FileManager.default
        var existingPrefix = url.standardizedFileURL
        var missingSuffix: [String] = []

        while existingPrefix.path != "/" {
            if fileManager.fileExists(atPath: existingPrefix.path) { break }
            do {
                // fileExists follows links and returns false for dangling ones.
                // Their target cannot be safely canonicalized here, so fail closed.
                _ = try fileManager.destinationOfSymbolicLink(atPath: existingPrefix.path)
                return nil
            } catch {
                missingSuffix.append(existingPrefix.lastPathComponent)
                existingPrefix.deleteLastPathComponent()
            }
        }

        var resolved = existingPrefix.standardizedFileURL.resolvingSymlinksInPath()
        for component in missingSuffix.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.pathComponents.map { $0.lowercased() }
    }
}
