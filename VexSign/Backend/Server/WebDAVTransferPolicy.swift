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

    /// Resolve symlinks one path component at a time. `resolvingSymlinksInPath()`
    /// may leave a symlink unresolved when the path has a nonexistent suffix
    /// (for example, `alias/new-file`); resolving each existing component keeps
    /// those destinations inside the same containment checks as existing paths.
    private static func components(_ url: URL) -> [String]? {
        guard url.isFileURL else { return nil }

        var pending = Array(url.standardizedFileURL.pathComponents.dropFirst())
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        var symlinkCount = 0
        let fileManager = FileManager.default

        while !pending.isEmpty {
            let component = pending.removeFirst()
            guard !component.isEmpty, component != "/" else { continue }
            let candidate = resolved.appendingPathComponent(component)

            do {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: candidate.path)
                symlinkCount += 1
                // Fail closed on a symlink cycle or an unexpectedly deep chain.
                guard symlinkCount <= 40 else { return nil }
                let target = destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination, isDirectory: true)
                    : resolved.appendingPathComponent(destination, isDirectory: true)
                pending = Array(target.standardizedFileURL.pathComponents.dropFirst()) + pending
                resolved = URL(fileURLWithPath: "/", isDirectory: true)
            } catch {
                // A non-symlink path component is expected; the remaining path
                // components will be checked individually as they are visited.
                resolved = candidate
            }
        }

        return resolved.standardizedFileURL.pathComponents.map { $0.lowercased() }
    }
}
