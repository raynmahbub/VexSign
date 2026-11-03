import Foundation
import SideSign

/// Transport only; not NativeProfileCreationPortal authority or signing readiness.
/// Future bound adapter must revalidate owner/context/resources and CMS gating.
protocol SideSignProfileTransport: SideSignRegistrationTransport {
    func profileCertificateInventory(team: Team, session: Session) async throws -> [NativeProfileCertificateObservation]
    func profileInventory(request: NativeProfileCreationRequest, team: Team, session: Session,
                          checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> [NativeProfileObservation]
    func createLimitedProfileOnce(request: NativeProfileCreationRequest, operationID: UUID, team: Team, session: Session) async throws
}

struct SideSignProfileInventoryPolicy {
    static func candidates(_ rows: [VexSignProfileListing], request: NativeProfileCreationRequest) throws -> [VexSignProfileListing] {
        guard rows.count <= 50, Set(rows.map(\.provisioningProfileId)).count == rows.count,
              Set(rows.map(\.uuid)).count == rows.count,
              rows.allSatisfy({ NativeRegistrationRecord.validIdentifier($0.provisioningProfileId)
                  && NativeRegistrationRecord.validIdentifier($0.appId.appIdId)
                  && SideSignRegistrationInventoryPolicy.validPortalBundle($0.appId.identifier) }) else {
            throw NativeProfileCreationError.inventoryRejected
        }
        var result: [VexSignProfileListing] = []
        for row in rows {
            let sameBundle = row.appId.identifier.caseInsensitiveCompare(request.validation.bundleIdentifier) == .orderedSame
            let sameRemote = row.appId.appIdId == request.appID
            if sameBundle || sameRemote {
                guard sameBundle, sameRemote, row.appId.identifier == request.validation.bundleIdentifier else {
                    throw NativeProfileCreationError.inventoryRejected
                }
                if let selected = request.validation.expectedUUID, row.uuid != selected { continue }
                result.append(row)
            }
        }
        return result
    }

    static func observation(_ download: VexSignDownloadedProfile, listing: VexSignProfileListing) throws -> NativeProfileObservation {
        guard download.provisioningProfileId == listing.provisioningProfileId, download.uuid == listing.uuid,
              !download.encodedProfile.isEmpty, download.encodedProfile.count <= 1024 * 1024 else {
            throw NativeProfileCreationError.inventoryRejected
        }
        return NativeProfileObservation(remoteIdentifier: download.provisioningProfileId,
                                        cms: download.encodedProfile, listedUUID: listing.uuid)
    }
}
