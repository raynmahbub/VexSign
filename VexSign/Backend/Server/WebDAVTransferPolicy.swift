import Foundation

/// Prevent an overwrite from deleting the source or the WebDAV inbox itself.
enum WebDAVTransferPolicy {
    static func permits(source: URL, destination: URL, inbox: URL) -> Bool {
        // Resolve existing symlinks and normalize dot segments. Case-folding is
        // conservative on case-sensitive volumes and protects typical iOS volumes.
        //
        // `resolvingSymlinksInPath()` only resolves symlinks when the path exists. A
        // destination that has not been created yet — `alias/new`, where `alias` is a
        // symlink to the source — came back untouched, so the alias stopped being
        // visible exactly when it mattered: before the write that would follow it.
        // Resolve the deepest existing ancestor and re-append the components that do
        // not exist yet, which is well defined for not-yet-created paths.
        func components(_ url: URL) -> [String] {
            var existing = url.standardizedFileURL
            var pending: [String] = []
            while !FileManager.default.fileExists(atPath: existing.path) {
                let parent = existing.deletingLastPathComponent()
                // `deletingLastPathComponent()` of `/` is `/`: stop rather than spin.
                guard parent.path != existing.path else { break }
                pending.insert(existing.lastPathComponent, at: 0)
                existing = parent
            }
            let resolved = existing.resolvingSymlinksInPath()
            return (resolved.pathComponents + pending).map { $0.lowercased() }
        }
        let root = components(inbox)
        let from = components(source)
        let to = components(destination)
        func contains(_ parent: [String], _ child: [String]) -> Bool {
            child.count >= parent.count && Array(child.prefix(parent.count)) == parent
        }
        guard contains(root, from), contains(root, to), from != root, to != root else { return false }
        return !contains(from, to) && !contains(to, from)
    }
}
