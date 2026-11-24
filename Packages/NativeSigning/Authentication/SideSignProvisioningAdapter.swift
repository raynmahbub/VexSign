import Foundation
import SideSign

/// Read-only portal surface: no revocation, deletion, registration, CSR submission
/// or auto certificate creation. The hardened native portal implements this using
/// the same ephemeral/system-TLS/redirect-denying transport as authentication.
protocol SideSignProvisioningPortal: SideSignAccountPortal {
    func fetchDevices(for team: Team, types: DeviceType, session: Session) async throws -> [Device]
    func fetchAppIDs(for team: Team, session: Session) async throws -> [AppID]
    func fetchCertificates(for team: Team, session: Session) async throws -> [X509Certificate]
}

struct SideSignProvisioningAdapter<Portal: SideSignProvisioningPortal>: Sendable {
    let portal: Portal

    func inventory(encodedSession: Data, headers: AnisetteData, teamIdentifier: String,
                   request: NativeAccountProvisioningRequest, now: Date,
                   checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> SideSignProvisioningInventory {
        do {
            try await checkCurrent()
            let auth = try SideSignSessionCodec.decodeForRevalidation(encodedSession, freshAnisetteData: headers, now: now)
            let account = try await portal.fetchAccount(session: auth.session)
            try await checkCurrent()
            guard account.identifier == auth.account.identifier,
                  account.appleID.lowercased() == auth.account.appleID.lowercased() else {
                throw NativeProvisioningError.inventoryRejected
            }
            let teams = try await portal.fetchTeams(for: account, session: auth.session)
            try await checkCurrent()
            guard teams.count <= 100, Set(teams.map(\.identifier)).count == teams.count,
                  let team = teams.first(where: { $0.identifier == teamIdentifier }),
                  team.account.map({ $0.identifier == account.identifier }) ?? true else {
                throw NativeProvisioningError.inventoryRejected
            }
            // Do not infer paid enrollment from the SDK's individual/org labels.
            guard team.type == .free else { throw NativeProvisioningError.unsupportedMembership }
            let devices = try await portal.fetchDevices(for: team, types: .all, session: auth.session)
            try await checkCurrent()
            guard devices.count <= 1000 else { throw NativeProvisioningError.inventoryRejected }
            let apps = try await portal.fetchAppIDs(for: team, session: auth.session)
            try await checkCurrent()
            guard apps.count <= 1000 else { throw NativeProvisioningError.inventoryRejected }
            let certificates = try await portal.fetchCertificates(for: team, session: auth.session)
            try await checkCurrent()
            guard devices.count <= 1000, apps.count <= 1000, certificates.count <= 1000,
                  Set(devices.map { $0.identifier.lowercased() }).count == devices.count,
                  Set(apps.map(\.identifier)).count == apps.count,
                  Set(apps.map { $0.bundleIdentifier.lowercased() }).count == apps.count,
                  devices.allSatisfy({ !$0.identifier.isEmpty && $0.identifier.utf8.count <= 128 }),
                  apps.allSatisfy({ !$0.identifier.isEmpty && $0.identifier.utf8.count <= 256
                      && NativeAccountProvisioningRequest.isBundleIdentifier($0.bundleIdentifier) }) else {
                throw NativeProvisioningError.inventoryRejected
            }
            // Missing/unknown device status is not proof of usable registration.
            // Conflicting/expired AppIDs fail closed instead of blind recreation.
            let matchingDevices = devices.filter { $0.identifier.caseInsensitiveCompare(request.deviceIdentifier) == .orderedSame }
            if let device = matchingDevices.first {
                guard device.type == .iPhone || device.type == .iPad,
                      device.status?.lowercased() == "enabled" else { throw NativeProvisioningError.inventoryRejected }
            }
            let requested = Set(request.bundleIdentifiers.map { $0.lowercased() })
            let matchingApps = apps.filter { requested.contains($0.bundleIdentifier.lowercased()) }
            guard matchingApps.allSatisfy({ request.bundleIdentifiers.contains($0.bundleIdentifier) }),
                  matchingApps.allSatisfy({ $0.expirationDate.map { $0 > now } ?? true }) else {
                throw NativeProvisioningError.inventoryRejected
            }
            return SideSignProvisioningInventory(deviceRegistered: !matchingDevices.isEmpty,
                appIdentifiers: Set(matchingApps.map(\.bundleIdentifier)), certificateCount: certificates.count,
                validUntil: matchingApps.compactMap(\.expirationDate).min())
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeProvisioningError { throw safe }
            throw NativeProvisioningError.requestFailed
        }
    }

    // Profile download by UUID lives on SideSignProfileTransport (implemented
    // by SideSignNativePortal and test doubles); this read-only adapter has no
    // download of its own, so callers use the transport directly.
}
