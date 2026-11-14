import Foundation
import SideSign

/// Native registration uses bounded, strict-status inventory and mutation APIs,
/// not SDK conveniences which can default malformed inventories to empty arrays.
protocol SideSignRegistrationTransport: SideSignProvisioningPortal {
    func registrationInventory(subject: NativeRegistrationSubject, team: Team, session: Session) async throws -> [NativeRegistrationObservation]
    func registerSubjectOnce(_ subject: NativeRegistrationSubject, operationID: UUID, team: Team, session: Session) async throws
}

struct SideSignRegistrationInventoryPolicy {
    static func observations(_ inventory: VexSignRegistrationInventory, subject: NativeRegistrationSubject,
                             now: Date) throws -> [NativeRegistrationObservation] {
        guard now.timeIntervalSince1970.isFinite else { throw NativeRegistrationError.inventoryRejected }
        switch inventory {
        case .devices(let rows):
            guard subject.kind == .device, rows.count <= 1000,
                  Set(rows.map { $0.deviceNumber.uppercased() }).count == rows.count else { throw NativeRegistrationError.inventoryRejected }
            let observations = try rows.map { row in
                let value: NativeRegistrationSubject
                do { value = try NativeRegistrationSubject(kind: .device, value: row.deviceNumber) }
                catch { throw NativeRegistrationError.inventoryRejected }
                let id = row.deviceId ?? row.deviceNumber
                guard NativeRegistrationRecord.validIdentifier(id), row.status.utf8.count <= 64,
                      row.deviceClass.utf8.count <= 64 else { throw NativeRegistrationError.inventoryRejected }
                let ios = ["iphone", "ipad"].contains(row.deviceClass.lowercased())
                return NativeRegistrationObservation(subject: value, remoteIdentifier: id,
                    enabled: ios && row.status.lowercased() == "enabled", expiresAt: nil)
            }
            guard Set(observations.map(\.remoteIdentifier)).count == observations.count else { throw NativeRegistrationError.inventoryRejected }
            return observations
        case .appIDs(let rows):
            guard subject.kind == .appID, rows.count <= 1000,
                  Set(rows.map(\.appIdId)).count == rows.count,
                  Set(rows.map { $0.identifier.lowercased() }).count == rows.count,
                  rows.allSatisfy({ NativeRegistrationRecord.validIdentifier($0.appIdId) && validPortalBundle($0.identifier)
                      && ($0.expirationDate.map { $0.timeIntervalSince1970.isFinite } ?? true) }) else {
                throw NativeRegistrationError.inventoryRejected
            }
            // Existing unrelated wildcard IDs are allowed in inventory, but never
            // converted to explicit registrations or accepted for this request.
            return try rows.filter { $0.identifier.caseInsensitiveCompare(subject.value) == .orderedSame }.map { row in
                let target = try NativeRegistrationSubject(kind: .appID, value: row.identifier)
                return NativeRegistrationObservation(subject: target, remoteIdentifier: row.appIdId,
                    enabled: row.expirationDate.map { $0 > now } ?? false, expiresAt: row.expirationDate)
            }
        }
    }

    static func validPortalBundle(_ value: String) -> Bool {
        if NativeAccountProvisioningRequest.isBundleIdentifier(value) { return true }
        if value == "*" { return true }
        guard value.hasSuffix(".*") else { return false }
        return NativeAccountProvisioningRequest.isBundleIdentifier(String(value.dropLast(2)) + ".placeholder")
    }
}
