import Foundation

struct NativeProfileCertificateObservation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let identifier: String
    let certificateDER: Data
    var description: String { "NativeProfileCertificateObservation(redacted)" }
    var debugDescription: String { description }
}

/// Binding checks only, NOT certificate trust, purpose or revocation validation.
struct NativeProfileResourcePolicy {
    static func requireOwned(_ owned: NativeOwnedProfileIdentity, request: NativeProfileCreationRequest) throws {
        let expected = request.validation; let actual = owned.validation
        guard owned.identityID == request.identityID, owned.certificateIdentifier == request.certificateID,
              actual.teamIdentifier == expected.teamIdentifier, actual.bundleIdentifier == expected.bundleIdentifier,
              actual.deviceIdentifier == expected.deviceIdentifier, actual.certificateDER == expected.certificateDER else {
            throw NativeProfileCreationError.invalidRequest
        }
    }

    static func requireRegistration(_ rows: [NativeRegistrationObservation], subject: NativeRegistrationSubject,
                                    remoteIdentifier: String, now: Date, requireExpiry: Bool) throws {
        guard now.timeIntervalSince1970.isFinite, rows.count <= 1000,
              NativeRegistrationRecord.validIdentifier(remoteIdentifier),
              Set(rows.map(\.remoteIdentifier)).count == rows.count,
              rows.allSatisfy({ NativeRegistrationRecord.validIdentifier($0.remoteIdentifier) && $0.subject.kind == subject.kind }) else {
            throw NativeProfileCreationError.inventoryRejected
        }
        let matches = rows.filter { $0.subject.value.caseInsensitiveCompare(subject.value) == .orderedSame }
        guard matches.count == 1, let row = matches.first,
              row.subject == subject, row.remoteIdentifier == remoteIdentifier, row.enabled,
              (!requireExpiry || row.expiresAt != nil),
              row.expiresAt.map({ $0.timeIntervalSince1970.isFinite && $0 > now }) ?? true else {
            throw NativeProfileCreationError.inventoryRejected
        }
    }

    static func requireCertificate(_ rows: [NativeProfileCertificateObservation], request: NativeProfileCreationRequest) throws {
        guard rows.count <= 1000,
              rows.allSatisfy({ NativeRegistrationRecord.validIdentifier($0.identifier) && !$0.certificateDER.isEmpty && $0.certificateDER.count <= 64 * 1024 }),
              Set(rows.map(\.identifier)).count == rows.count,
              Set(rows.map { NativeSigningIdentityOwner.hash($0.certificateDER) }).count == rows.count else {
            throw NativeProfileCreationError.inventoryRejected
        }
        let matches = rows.filter { $0.identifier == request.certificateID || $0.certificateDER == request.validation.certificateDER }
        guard matches.count == 1, let row = matches.first,
              row.identifier == request.certificateID, row.certificateDER == request.validation.certificateDER else {
            throw NativeProfileCreationError.inventoryRejected
        }
    }
}
