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
}


extension AppInfoPresentable {
    var recordID: String? { nil }
    var bundleURL: URL? { nil }
    var artifactURL: URL? { nil }
}

extension AppInfoPresentable {
    /// Selection keys cannot conflate signed and imported copies with the same UUID.
    var workspaceIdentity: String? {
        if let recordID, !recordID.isEmpty { return recordID }
        guard let uuid, !uuid.isEmpty else { return nil }
        return "\(isSigned ? "signed" : "imported"):\(uuid)"
    }
}
