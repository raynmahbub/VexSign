import Foundation
import SideSign

/// Narrow surface for deterministic tests; no certificate/provisioning methods.
public protocol SideSignAccountPortal: Sendable {
    func authenticate(appleID: String, password: String, anisetteData: AnisetteData,
                      xcodeVersion: String, machinePassword: String?,
                      accountRepairHandler: DeveloperPortal.AccountRepairHandler,
                      verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> AuthSession
    func fetchAccount(session: Session) async throws -> Account
    func fetchTeams(for account: Account, session: Session) async throws -> [Team]
}

extension DeveloperPortal: SideSignAccountPortal {}

public enum SideSignAccountAdapterError: Error, Equatable {
    case invalidInput
    case incorrectCredentials
    case appSpecificPasswordRequired
    case accountRepairRequired
    case tooManyAttempts
    case noTeams
    case unsupportedTeam
    case invalidPortalResponse
    case transportSecurityFailure
    case requestFailed
    case unsafeSDKConfiguration
}

/// Does not assert an active paid enrollment based on the SDK's inferred type.
/// Provisioning/entitlement eligibility must be checked independently later.
public struct SideSignAccountTeam: Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let category: TeamType
}

/// Secret bytes are destined only for durable device-only Keychain commit.
/// Teams still require explicit selection; this is NOT a signing context.
public struct SideSignPreparedAccountSession: Sendable {
    public let encodedSession: Data
    public let teams: [SideSignAccountTeam]
    public let expiresAt: Date
}

/// Real SideSign calls, isolated from the app until native integration is verified.
/// Password exists only as an in-flight argument, not a stored property. Swift
/// String copies cannot be promised to zeroize. No logging or raw SDK error escape.
public struct SideSignAccountAdapter<Portal: SideSignAccountPortal>: Sendable {
    private let portal: Portal
    private let clock: @Sendable () -> Date
    // Internal only: the provisioning adapter shares the hardened portal rather
    // than introducing DeveloperPortal.shared or another credential transport.
    var provisioningPortal: Portal { portal }

    // Injectable only inside this module/tests. Production uses the hardened
    // native portal below, not DeveloperPortal.shared or an arbitrary URLSession.
    init(portal: Portal, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.portal = portal
        self.clock = clock
    }

    public func authenticate(
        appleID: String, password: String, freshAnisetteData: AnisetteData,
        xcodeVersion: String, twoFactor: SideSignTwoFactorBroker,
        onTwoFactor: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> SideSignPreparedAccountSession {
        do {
            try Task.checkCancellation()
            guard !appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  appleID.utf8.count <= 1024, !password.isEmpty, password.utf8.count <= 4096,
                  !xcodeVersion.isEmpty, xcodeVersion.utf8.count <= 256 else {
                throw SideSignAccountAdapterError.invalidInput
            }
            try SideSignSessionCodec.validateFreshHeaders(freshAnisetteData)
            let authenticated = try await portal.authenticate(
                appleID: appleID, password: password, anisetteData: freshAnisetteData,
                xcodeVersion: xcodeVersion, machinePassword: nil,
                accountRepairHandler: { _, _ in .cancel },
                verificationHandler: { request in
                    try Task.checkCancellation()
                    try await onTwoFactor()
                    let response = try await twoFactor.request(request)
                    try Task.checkCancellation()
                    return response
                }
            )
            try Task.checkCancellation()
            let prepared = try await prepare(authenticated)
            await twoFactor.cancel()
            try Task.checkCancellation()
            return prepared
        } catch {
            await twoFactor.cancel()
            throw sanitized(error)
        }
    }

    /// Existing token must survive fetchAccount + fresh team enumeration before
    /// returning. Does not auto-select the persisted hint or restore app state.
    public func revalidate(encodedSession: Data, freshAnisetteData: AnisetteData) async throws -> SideSignPreparedAccountSession {
        try Task.checkCancellation()
        do {
            let candidate = try SideSignSessionCodec.decodeForRevalidation(
                encodedSession, freshAnisetteData: freshAnisetteData, now: clock()
            )
            let account = try await portal.fetchAccount(session: candidate.session)
            try Task.checkCancellation()
            guard account.identifier == candidate.account.identifier,
                  account.appleID.lowercased() == candidate.account.appleID.lowercased() else {
                throw SideSignAccountAdapterError.invalidPortalResponse
            }
            return try await prepare(AuthSession(account: account, session: candidate.session))
        } catch { throw sanitized(error) }
    }

    private func prepare(_ authenticated: AuthSession) async throws -> SideSignPreparedAccountSession {
        try Task.checkCancellation()
        let values = try await portal.fetchTeams(for: authenticated.account, session: authenticated.session)
        try Task.checkCancellation()
        guard !values.isEmpty else { throw SideSignAccountAdapterError.noTeams }
        guard values.count <= 100, Set(values.map(\.identifier)).count == values.count else {
            throw SideSignAccountAdapterError.invalidPortalResponse
        }
        var teams: [SideSignAccountTeam] = []
        for team in values {
            guard !team.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  team.identifier.utf8.count <= 256, team.name.utf8.count <= 1024,
                  !team.identifier.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !team.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  team.account.map({ $0.identifier == authenticated.account.identifier }) ?? true else {
                throw SideSignAccountAdapterError.invalidPortalResponse
            }
            switch team.type {
            case .free, .individual, .organization: break
            case .unknown: throw SideSignAccountAdapterError.unsupportedTeam
            @unknown default: throw SideSignAccountAdapterError.unsupportedTeam
            }
            teams.append(SideSignAccountTeam(identifier: team.identifier, name: team.name, category: team.type))
        }
        let now = clock()
        let encoded = try SideSignSessionCodec.encode(authenticated, now: now)
        let canonical = try SideSignSessionCodec.decodeForRevalidation(
            encoded, freshAnisetteData: authenticated.session.anisetteData, now: now
        )
        guard let expiry = canonical.session.expirationDate else {
            throw SideSignAccountAdapterError.invalidPortalResponse
        }
        try Task.checkCancellation()
        return SideSignPreparedAccountSession(encodedSession: encoded, teams: teams, expiresAt: expiry)
    }

    private func sanitized(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let safe = error as? SideSignAccountAdapterError { return safe }
        if let safe = error as? SideSignSessionCodecError { return safe }
        if let portalError = error as? DeveloperPortalError {
            switch portalError {
            case .userCancelled: return CancellationError()
            case .incorrectCredentials: return SideSignAccountAdapterError.incorrectCredentials
            case .appSpecificPasswordRequired: return SideSignAccountAdapterError.appSpecificPasswordRequired
            case .accountRepairRequired: return SideSignAccountAdapterError.accountRepairRequired
            case .tooManyAttempts: return SideSignAccountAdapterError.tooManyAttempts
            case .noTeams: return SideSignAccountAdapterError.noTeams
            default: break
            }
        }
        if let transport = error as? URLError {
            switch transport.code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return SideSignAccountAdapterError.transportSecurityFailure
            default: break
            }
        }
        return SideSignAccountAdapterError.requestFailed
    }
}

/// A dedicated ephemeral transport: no shared cookies, caches or credentials;
/// deny redirects so custom Apple identity headers cannot follow another URL.
/// System TLS evaluation is untouched; no trust bypass or remote signing service.
public final class SideSignNativePortal: SideSignAccountPortal, Sendable {
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let session: URLSession
    private let portal: DeveloperPortal

    public init() throws {
        // Missing overlays fail compilation, not a runtime "available" heuristic.
        // Unexpected marker failure must be surfaced, never force-close the app.
        guard VexSignSideSignPrivacy.loggingSuppressed else {
            throw SideSignAccountAdapterError.unsafeSDKConfiguration
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        self.session = session
        self.portal = DeveloperPortal(session: session)
    }

    deinit { session.invalidateAndCancel() }

    public func authenticate(appleID: String, password: String, anisetteData: AnisetteData,
                             xcodeVersion: String, machinePassword: String?,
                             accountRepairHandler: DeveloperPortal.AccountRepairHandler,
                             verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> AuthSession {
        try await portal.authenticate(appleID: appleID, password: password, anisetteData: anisetteData,
                                      xcodeVersion: xcodeVersion, machinePassword: machinePassword,
                                      accountRepairHandler: accountRepairHandler, verificationHandler: verificationHandler)
    }
    public func fetchAccount(session: Session) async throws -> Account { try await portal.fetchAccount(session: session) }
    public func fetchTeams(for account: Account, session: Session) async throws -> [Team] {
        try await portal.fetchTeams(for: account, session: session)
    }
}

public extension SideSignAccountAdapter where Portal == SideSignNativePortal {
    init() throws { self.init(portal: try SideSignNativePortal()) }
}


extension SideSignNativePortal: SideSignProvisioningPortal {
    func fetchDevices(for team: Team, types: DeviceType, session: Session) async throws -> [Device] {
        try await portal.fetchDevices(for: team, types: types, session: session)
    }
    func fetchAppIDs(for team: Team, session: Session) async throws -> [AppID] {
        try await portal.fetchAppIDs(for: team, session: session)
    }
    func fetchCertificates(for team: Team, session: Session) async throws -> [X509Certificate] {
        try await portal.fetchCertificates(for: team, session: session)
    }
}


extension SideSignNativePortal: SideSignPreparedCSRPortal {
    func submitPreparedDevelopmentCSR(_ submission: NativeSigningCSRSubmission, team: Team,
                                      session: Session) async throws -> NativeSigningCertificateObservation? {
        do {
            let receipt = try await portal.vexsignSubmitPreparedDevelopmentCSR(csrDER: submission.csrDER,
                machineIdentifier: submission.identityID, team: team, session: session)
            guard let identifier = receipt.certificateIdentifier, let der = receipt.certificateDER else { return nil }
            return NativeSigningCertificateObservation(identifier: identifier, certificateDER: der)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NativeSigningIdentityError.reconciliationRequired
        }
    }
}


extension SideSignNativePortal: SideSignRegistrationTransport {
    func registrationInventory(subject: NativeRegistrationSubject, team: Team, session: Session) async throws -> [NativeRegistrationObservation] {
        do {
            // DeveloperPortal speaks SideSign's overlay types; the policies
            // below speak this module's copies, so map at the boundary.
            let kind: SideSign.VexSignRegistrationKind = subject.kind == .device ? .device : .appID
            let inventory = try await portal.vexsignRegistrationInventory(kind: kind, team: team, session: session)
            try Task.checkCancellation()
            let local: VexSignRegistrationInventory
            switch inventory {
            case .devices(let rows):
                local = .devices(rows.map { VexSignRegistrationDevice(deviceNumber: $0.deviceNumber, deviceId: $0.deviceId, deviceClass: $0.deviceClass, status: $0.status) })
            case .appIDs(let rows):
                local = .appIDs(rows.map { VexSignRegistrationAppID(appIdId: $0.appIdId, identifier: $0.identifier, expirationDate: $0.expirationDate) })
            }
            return try SideSignRegistrationInventoryPolicy.observations(local, subject: subject, now: Date())
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NativeRegistrationError.inventoryRejected
        }
    }

    func registerSubjectOnce(_ subject: NativeRegistrationSubject, operationID: UUID, team: Team, session: Session) async throws {
        do {
            let kind: SideSign.VexSignRegistrationKind = subject.kind == .device ? .device : .appID
            try await portal.vexsignRegisterOnce(kind: kind, value: subject.value, operationID: operationID, team: team, session: session)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NativeRegistrationError.reconciliationRequired
        }
    }
}


extension SideSignNativePortal: SideSignProfileTransport {
    func profileCertificateInventory(team: Team, session: Session) async throws -> [NativeProfileCertificateObservation] {
        do {
            let rows = try await portal.vexsignDevelopmentCertificates(team: team, session: session)
            try Task.checkCancellation()
            return try NativeProfileCertificateInventoryPolicy.observations(
                rows.map { VexSignDevelopmentCertificate(certificateId: $0.certificateId, certContent: $0.certContent) })
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NativeProfileCreationError.inventoryRejected
        }
    }

    func profileInventory(request: NativeProfileCreationRequest, team: Team, session: Session,
                          checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> [NativeProfileObservation] {
        do {
            try await checkCurrent(); try Task.checkCancellation()
            let rows = try await portal.vexsignListProfiles(team: team, session: session)
            try await checkCurrent(); try Task.checkCancellation()
            let candidates = try SideSignProfileInventoryPolicy.candidates(
                rows.map { VexSignProfileListing(provisioningProfileId: $0.provisioningProfileId, uuid: $0.uuid,
                                                 appId: .init(appIdId: $0.appId.appIdId, identifier: $0.appId.identifier)) },
                request: request)
            var observations: [NativeProfileObservation] = []
            var total = 0
            for listing in candidates {
                try await checkCurrent(); try Task.checkCancellation()
                let downloaded = try await portal.vexsignDownloadProfile(id: listing.provisioningProfileId, team: team, session: session)
                try await checkCurrent(); try Task.checkCancellation()
                let observation = try SideSignProfileInventoryPolicy.observation(
                    VexSignDownloadedProfile(provisioningProfileId: downloaded.provisioningProfileId, uuid: downloaded.uuid,
                                             encodedProfile: downloaded.encodedProfile),
                    listing: listing)
                total += observation.cms.count
                guard total <= 4 * 1024 * 1024 else { throw NativeProfileCreationError.inventoryRejected }
                observations.append(observation)
            }
            return observations // partial/failed download is NEVER empty success
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NativeProfileCreationError.inventoryRejected
        }
    }

    func createLimitedProfileOnce(request: NativeProfileCreationRequest, operationID: UUID, team: Team, session: Session) async throws {
        do {
            try await portal.vexsignCreateLimitedProfileOnce(appID: request.appID, certificateID: request.certificateID,
                deviceID: request.deviceID, operationID: operationID, team: team, session: session)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NativeProfileCreationError.reconciliationRequired
        }
    }

    func downloadProvisioningProfile(
        encodedSession: Data,
        headers: AnisetteData,
        teamIdentifier: String,
        profileUUID: UUID,
        now: Date
    ) async throws -> Data {
        do {
            try Task.checkCancellation()
            let auth = try SideSignSessionCodec.decodeForRevalidation(encodedSession, freshAnisetteData: headers, now: now)
            let account = try await fetchAccount(session: auth.session)
            try Task.checkCancellation()
            guard account.identifier == auth.account.identifier,
                  account.appleID.lowercased() == auth.account.appleID.lowercased() else {
                throw NativeProvisioningError.inventoryRejected
            }
            let teams = try await fetchTeams(for: account, session: auth.session)
            try Task.checkCancellation()
            guard teams.count <= 100, Set(teams.map(\.identifier)).count == teams.count,
                  let team = teams.first(where: { $0.identifier == teamIdentifier }),
                  team.account.map({ $0.identifier == account.identifier }) ?? true else {
                throw NativeProvisioningError.inventoryRejected
            }
            let downloaded = try await portal.vexsignDownloadProfile(id: profileUUID.uuidString, team: team, session: auth.session)
            try Task.checkCancellation()
            guard downloaded.provisioningProfileId == profileUUID.uuidString,
                  !downloaded.encodedProfile.isEmpty, downloaded.encodedProfile.count <= 1024 * 1024 else {
                throw NativeProvisioningError.requestFailed
            }
            return downloaded.encodedProfile
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeProvisioningError { throw safe }
            throw NativeProvisioningError.requestFailed
        }
    }
}
