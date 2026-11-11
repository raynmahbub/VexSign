import Foundation

/// Prevent an overwrite from deleting the source or the WebDAV inbox itself.
enum WebDAVTransferPolicy {
    static func permits(source: URL, destination: URL, inbox: URL) -> Bool {
        // Resolve existing symlinks and normalize dot segments. Case-folding is
        // conservative on case-sensitive volumes and protects typical iOS volumes.
        func components(_ url: URL) -> [String] {
            url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
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
