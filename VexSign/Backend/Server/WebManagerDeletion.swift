import Foundation

/// Keep the HTTP result aligned with the outcome of the filesystem operation.
enum WebManagerDeletion {
    enum Result: Equatable {
        case removed
        case missing
        case failed
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
