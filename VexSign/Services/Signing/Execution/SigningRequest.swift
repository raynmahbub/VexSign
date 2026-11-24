import CoreData
import Foundation
import NimbleExtensions
import UIKit

/// The service's events carry an opaque committed library identity, never a managed object.
typealias SigningEvent = SigningWorkflowEvent<LibraryAppReference>

/// Immutable app metadata captured on the main actor. This is the only app-shaped value a worker
/// receives; it cannot fault Core Data or retain a view-context row.
struct SigningAppSnapshot: AppInfoPresentable, Sendable {
    let recordID: String?
    let bundleURL: URL?
    let artifactURL: URL?
    let name: String?
    let version: String?
    let identifier: String?
    let originalIdentifier: String?
    let date: Date?
    let source: URL?
    let icon: String?
    let uuid: String?
    let isSigned: Bool
    let appDescription: String?

    init(_ app: AppInfoPresentable) {
        recordID = app.recordID
        bundleURL = app.bundleURL
        artifactURL = app.artifactURL
        name = app.name
        version = app.version
        identifier = app.identifier
        originalIdentifier = app.originalIdentifier
        date = app.date
        source = app.source
        icon = app.icon
        uuid = app.uuid
        isSigned = app.isSigned
        appDescription = app.appDescription
    }

    static let invalid = SigningAppSnapshot(
        recordID: nil, bundleURL: nil, artifactURL: nil, name: nil, version: nil,
        identifier: nil, originalIdentifier: nil, date: nil, source: nil, icon: nil, uuid: nil,
        isSigned: false, appDescription: nil
    )

    private init(
        recordID: String?, bundleURL: URL?, artifactURL: URL?, name: String?, version: String?,
        identifier: String?, originalIdentifier: String?, date: Date?, source: URL?, icon: String?, uuid: String?,
        isSigned: Bool, appDescription: String?
    ) {
        self.recordID = recordID
        self.bundleURL = bundleURL
        self.artifactURL = artifactURL
        self.name = name
        self.version = version
        self.identifier = identifier
        self.originalIdentifier = originalIdentifier
        self.date = date
        self.source = source
        self.icon = icon
        self.uuid = uuid
        self.isSigned = isSigned
        self.appDescription = appDescription
    }
}

/// Value-only input accepted by the detached signing worker. UIKit and Core Data objects are
/// projected to bytes/opaque identifiers before this boundary; the worker resolves identities
/// on MainActor when it needs current persistence state.
struct SigningWorkRequest: Sendable {
    let id: String
    let app: SigningAppSnapshot
    let options: Options
    let iconData: Data?
    let certificateID: String?
    let appReferenceIsValid: Bool
    let overridesBlockingPreflightIssues: Bool
    let notices: [String]
    let authorization: SigningResolutionAuthorization?
}

/// What to sign, and how. This request remains on MainActor because callers may hold a managed
/// row, a certificate row and a UIImage. `workerValue()` snapshots those inputs before work is
/// detached, so none of those references escape into the worker.
struct SigningRequest: Identifiable {
    let id: String
    let app: AppInfoPresentable
    let options: Options
    let icon: UIImage?
    let certificate: CertificatePair?
    /// Explicit consent to nonmandatory preflight risks only. Authentication,
    /// identifier/profile compatibility, required capabilities and final signature
    /// verification cannot be bypassed, regardless of this flag.
    let overridesBlockingPreflightIssues: Bool
    /// Lines the caller needs in this run's log, written as warnings once the run has started.
    let notices: [String]
    var authorization: SigningResolutionAuthorization? = nil

    init(
        id: String = UUID().uuidString,
        app: AppInfoPresentable,
        options: Options,
        icon: UIImage?,
        certificate: CertificatePair?,
        overridesBlockingPreflightIssues: Bool = false,
        notices: [String] = []
    ) {
        self.id = id
        self.app = app
        self.options = options
        self.icon = icon
        self.certificate = certificate
        self.overridesBlockingPreflightIssues = overridesBlockingPreflightIssues
        self.notices = notices
    }

    var name: String {
        app.name ?? .localized("app")
    }

    @MainActor
    func workerValue() -> SigningWorkRequest {
        let appSnapshot: SigningAppSnapshot
        let appReferenceIsValid: Bool
        if app is Signed || app is Imported {
            do {
                let record = try CoreDataWorkspaceRepository(storage: Storage.shared).appRecord(app)
                appSnapshot = SigningAppSnapshot(record)
                appReferenceIsValid = record.uuid?.isEmpty == false
            } catch {
                // Do not read properties from a foreign/deleted managed object on the worker.
                appSnapshot = .invalid
                appReferenceIsValid = false
            }
        } else if let managedObject = app as? NSManagedObject {
            // Other Core Data entities do not become valid library app references by conforming
            // to the presentation protocol.
            _ = managedObject
            appSnapshot = .invalid
            appReferenceIsValid = false
        } else {
            appSnapshot = SigningAppSnapshot(app)
            appReferenceIsValid = appSnapshot.uuid?.isEmpty == false
        }

        let certificateID: String?
        if let certificate,
           certificate.managedObjectContext === Storage.shared.context,
           !certificate.isDeleted,
           !certificate.objectID.isTemporaryID {
            certificateID = certificate.objectID.uriRepresentation().absoluteString
        } else {
            certificateID = nil
        }

        return SigningWorkRequest(
            id: id,
            app: appSnapshot,
            options: options,
            iconData: icon?.pngData(),
            certificateID: certificateID,
            appReferenceIsValid: appReferenceIsValid,
            overridesBlockingPreflightIssues: overridesBlockingPreflightIssues,
            notices: notices,
            authorization: authorization
        )
    }
}
