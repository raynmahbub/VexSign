import Foundation

protocol AppInfoPresentable {
    /// Opaque persistent identity; never interpreted by a view.
    var recordID: String? { get }
    var bundleURL: URL? { get }
    var artifactURL: URL? { get }
	var name: String? { get }
	var version: String? { get }
	var identifier: String? { get }
	var originalIdentifier: String? { get }
	var date: Date? { get }
	var icon: String? { get }
	var uuid: String? { get }
	var isSigned: Bool { get }
	var appDescription: String? { get }
    /// Repository URL that supplied this library copy, when it came from a catalog.
    var source: URL? { get }
}


extension AppInfoPresentable {
    var recordID: String? { nil }
    var bundleURL: URL? { nil }
    var artifactURL: URL? { nil }
    var source: URL? { nil }
}

extension AppInfoPresentable {
    /// Selection keys cannot conflate signed and imported copies with the same UUID.
    var workspaceIdentity: String? {
        if let recordID, !recordID.isEmpty { return recordID }
        guard let uuid, !uuid.isEmpty else { return nil }
        return "\(isSigned ? "signed" : "imported"):\(uuid)"
    }
}
