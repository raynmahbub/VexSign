import Foundation

/// Prevent an overwrite from deleting the source or the WebDAV inbox itself.
enum WebDAVTransferPolicy {
    static func permits(source: URL, destination: URL, inbox: URL) -> Bool {
        // Foundation does not reliably resolve an intermediate symlink when the
        // final destination does not exist yet. Resolve the nearest existing
        // entry first, then reattach the nonexistent suffix so alias/new and
        // outside/new cannot evade the overlap and containment checks.
        func resolved(_ url: URL) -> URL {
            let manager = FileManager.default
            func entryExists(_ url: URL) -> Bool {
                if manager.fileExists(atPath: url.path) { return true }
                do {
                    return try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
                } catch {
                    return false
                }
            }

            var prefix = url.standardizedFileURL
            var suffix: [String] = []
            while !entryExists(prefix) {
                let parent = prefix.deletingLastPathComponent()
                guard parent != prefix else { break }
                suffix.insert(prefix.lastPathComponent, at: 0)
                prefix = parent
            }
            var result = prefix.resolvingSymlinksInPath().standardizedFileURL
            for component in suffix { result.appendPathComponent(component) }
            return result.standardizedFileURL
        }

        // Case-folding is conservative on case-sensitive volumes and protects
        // typical iOS volumes.
        func components(_ url: URL) -> [String] {
            resolved(url).pathComponents.map { $0.lowercased() }
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
