import Foundation

struct LibraryCloneRequest: Sendable {
    var customName: String?
    var customBundleIdentifier: String?
    var asUnsigned = false
    var iconOrdinal: Int?
}
@MainActor
protocol LibraryCloningProviding: AnyObject {
    func clone(_ source: LibraryAppReference, request: LibraryCloneRequest) async throws -> LibraryAppRecord
}
