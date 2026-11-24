import Foundation

/// Keep the HTTP result aligned with the outcome of the filesystem operation.
enum WebManagerDeletion {
    enum Result: Equatable {
        case removed
        case missing
        case failed
    }

    /// The result of deleting a record (an app, a tweak, a certificate) that may not
    /// exist and whose save may fail.
    ///
    /// The three routes used to answer `204` unconditionally, so a script that named
    /// an unknown id — or an app the vault hides — was told the work was done. This
    /// keeps the HTTP status honest and in one place.
    static func outcome(exists: Bool, removed: Bool) -> Result {
        guard exists else { return .missing }
        return removed ? .removed : .failed
    }

    static func isInboxRoot(_ url: URL, inbox: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath() == inbox.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func delete(_ url: URL,
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                       remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Result {
        guard exists(url.path) else { return .missing }
        do {
            try remove(url)
            return .removed
        } catch {
            // The item may also have disappeared after the existence check. A
            // conflict is conservative: it never reports an unverified removal.
            return .failed
        }
    }
}
