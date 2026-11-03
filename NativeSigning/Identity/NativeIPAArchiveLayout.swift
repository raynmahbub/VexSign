import Foundation

/// First supported namespace: one Payload/<name>.app main app. No content has
/// been inflated/CRC-checked, and filenames do not prove absence of hidden code.
/// A later all-entry content scanner is mandatory before signing authority.
struct NativeIPAArchiveLayout: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let appRoot: String
    let infoEntry: NativeIPAArchiveIndex.Entry
    private init(appRoot: String, infoEntry: NativeIPAArchiveIndex.Entry) { self.appRoot = appRoot; self.infoEntry = infoEntry }
    var description: String { "NativeIPAArchiveLayout(redacted; content unverified)" }
    var debugDescription: String { description }

    static func singleMainApp(_ index: NativeIPAArchiveIndex) throws -> Self {
        var roots = Set<String>()
        for entry in index.entries {
            let components = entry.path.split(separator: "/").map(String.init)
            guard components.first == "Payload" else { throw NativeIPAArchiveError.unsupportedLayout }
            if components.count == 1 {
                guard entry.isDirectory else { throw NativeIPAArchiveError.unsupportedLayout }
                continue
            }
            guard components[1].hasSuffix(".app"), components[1].count > 4 else { throw NativeIPAArchiveError.unsupportedLayout }
            roots.insert(components.prefix(2).joined(separator: "/"))
            if components.count == 2 {
                guard entry.isDirectory else { throw NativeIPAArchiveError.unsupportedLayout }
            }
            for component in components.dropFirst(2) {
                let name = component.lowercased()
                guard !["plugins", "watch", "frameworks"].contains(name),
                      ![".app", ".appex", ".framework", ".xpc", ".dylib"].contains(where: { name.hasSuffix($0) }) else {
                    throw NativeIPAArchiveError.unsupportedLayout
                }
            }
        }
        guard roots.count == 1, let root = roots.first,
              let info = index.entries.first(where: { $0.path == root + "/Info.plist" && !$0.isDirectory }),
              info.expandedCount > 0, info.expandedCount <= 256 * 1024 else { throw NativeIPAArchiveError.unsupportedLayout }
        return Self(appRoot: root, infoEntry: info)
    }
}
