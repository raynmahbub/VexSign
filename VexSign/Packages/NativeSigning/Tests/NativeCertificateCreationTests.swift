import Foundation
import XCTest
import SideSign
import os
@testable import NativeSigningLinkSmoke

/// Future native execution only. Fake vault/portal fixtures prove call ordering,
/// not cryptographic matching, real Keychain semantics or Apple issuance.
final class NativeCertificateCreationTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private actor Vault: NativeSigningIdentityManaging {
        private var pauseStatus = false
        private let exportFixture: Bool
        private var keyReads = 0
        func privateKeyReadCount() -> Int { keyReads }
        func privateKeyDER(owner: NativeSigningIdentityOwner, identityID: UUID, now: Date) async throws -> Data {
            keyReads += 1
            // Deliberately fail before PKCS#12 encoding; no usable key fixture.
            throw NativeSigningIdentityError.generationFailed
        }
        private var statusEntered = false
        private var statusEntry: CheckedContinuation<Void, Never>?
        private var statusRelease: CheckedContinuation<Void, Never>?
        func pauseOwnedStatus() { pauseStatus = true }
        func waitOwnedStatus() async {
            if statusEntered { return }
            await withCheckedContinuation { statusEntry = $0 }
        }
        func releaseOwnedStatus() {
            pauseStatus = false; statusEntered = true
            statusEntry?.resume(); statusEntry = nil
            statusRelease?.resume(); statusRelease = nil
        }
        func ownedSigningCertificate(owner: NativeSigningIdentityOwner, identityID: UUID, now: Date) async throws -> NativeOwnedSigningCertificate {
            if pauseStatus {
                statusEntered = true; statusEntry?.resume(); statusEntry = nil
                await withCheckedContinuation { statusRelease = $0 }
            }
            try Task.checkCancellation()
            if exportFixture, identityID == self.identityID, phase == .certificateRecorded {
                // Grant-order fixture only, not a cryptographic ownership proof.
                return .init(identityID: identityID, certificateIdentifier: "SYNTHETIC", certificateDER: Data([1]))
            }
            // This synthetic vault deliberately has no usable status certificate.
            throw NativeSigningIdentityError.reconciliationRequired
        }
        let identityID = UUID()
        private var phase: NativeSigningIdentityPhase
        init(phase: NativeSigningIdentityPhase = .prepared, exportFixture: Bool = false) {
            self.phase = phase; self.exportFixture = exportFixture
        }
        private func value() -> NativeSigningIdentityTicket {
            .init(id: identityID, teamIdentifier: "ABCDE12345", phase: phase, publicKeySHA256: "fixture", csrSHA256: "fixture")
        }
        func prepare(owner: NativeSigningIdentityOwner, now: Date) -> NativeSigningIdentityTicket { value() }
        func ticket(owner: NativeSigningIdentityOwner, identityID: UUID) throws -> NativeSigningIdentityTicket {
            guard identityID == self.identityID else { throw NativeSigningIdentityError.identityChanged }
            return value()
        }
        func beginSubmission(owner: NativeSigningIdentityOwner, identityID: UUID) throws -> NativeSigningCSRSubmission {
            guard phase == .prepared else { throw NativeSigningIdentityError.reconciliationRequired }
            phase = .submissionUncertain
            return .init(identityID: identityID, machineName: "VexSign-" + identityID.uuidString, csrDER: Data(repeating: 0, count: 64))
        }
        func recordCertificate(owner: NativeSigningIdentityOwner, identityID: UUID, certificateDER: Data,
                               certificateIdentifier: String, now: Date) -> NativeSigningIdentityTicket {
            phase = .certificateRecorded; return value()
        }
        func reconcileUncertain(owner: NativeSigningIdentityOwner, identityID: UUID,
                                certificates: [NativeSigningCertificateObservation], now: Date) -> NativeSigningIdentityTicket {
            // Synthetic successful recovery; real coordinator requires unique,
            // cryptographically bound certificate fixtures in its separate suite.
            phase = .certificateRecorded; return value()
        }
        func discardPrepared(owner: NativeSigningIdentityOwner, identityID: UUID) {}
        func ownedProfileIdentity(owner: NativeSigningIdentityOwner, identityID: UUID, bundleIdentifier: String,
                                  deviceIdentifier: String, now: Date) throws -> NativeOwnedProfileIdentity {
            guard identityID == self.identityID, phase == .certificateRecorded else { throw NativeSigningIdentityError.reconciliationRequired }
            return .init(identityID: identityID, certificateIdentifier: "CERT1", validation:
                try NativeProfileValidationRequest(teamIdentifier: owner.teamIdentifier, bundleIdentifier: bundleIdentifier,
                    deviceIdentifier: deviceIdentifier, certificateDER: Data([1])))
        }
        func currentPhase() -> NativeSigningIdentityPhase { phase }
    }
    private struct Lifetime: NativeAccountBackendLifetime {}
    private struct RegistrationStore: NativeRegistrationStorage {
        let lock = OSAllocatedUnfairLock<NativeRegistrationRecord?>(initialState: nil)
        func read(owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) -> NativeRegistrationRecord? { lock.withLock { $0 } }
        func insertIntent(_ record: NativeRegistrationRecord, owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws {
            try record.validate(owner: owner, subject: subject)
            try lock.withLock {
                guard $0 == nil else { throw NativeRegistrationError.storageUnavailable }; $0 = record
            }
        }
        func recordObservation(_ record: NativeRegistrationRecord, owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws {
            try record.validate(owner: owner, subject: subject)
            try lock.withLock {
                guard $0?.id == record.id, $0?.phase == .uncertain else { throw NativeRegistrationError.storageUnavailable }; $0 = record
            }
        }
    }
    private struct ProfileStore: NativeProfileCreationStorage {
        func listAllRecords(owner: NativeSigningIdentityOwner) throws -> [NativeProfileCreationRecord] {
            XCTFail("Default CMS gate must prevent profile journal enumeration")
            throw NativeProfileCreationError.storageUnavailable
        }
        func read(owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) -> NativeProfileCreationRecord? { nil }
        func insertIntent(_ record: NativeProfileCreationRecord, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws {
            XCTFail("Resource rejection must occur before intent"); throw NativeProfileCreationError.storageUnavailable
        }
        func recordObservation(_ record: NativeProfileCreationRecord, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws {
            XCTFail("No authenticated synthetic profile"); throw NativeProfileCreationError.storageUnavailable
        }
    }
    private struct RejectionVerifier: NativeProfileCMSVerifying {
        func verifyAppleProvisioningCMS(_ cms: Data, now: Date) async throws -> Data { throw NativeProfileValidationError.cmsRejected }
    }
    private struct ExportVerifier: NativeProfileCMSVerifying {
        let payload: Data
        func verifyAppleProvisioningCMS(_ cms: Data, now: Date) async throws -> Data { payload }
    }
    private struct ReceiptStore: NativeProfileReceiptStorage {
        let lock = OSAllocatedUnfairLock<[NativeProfileReceipt]>(initialState: [])
        func record(_ receipt: NativeProfileReceipt, owner: NativeSigningIdentityOwner) throws {
            lock.withLock { $0.append(receipt) }
        }
        func list(owner: NativeSigningIdentityOwner) throws -> [NativeProfileReceipt] {
            lock.withLock { $0.filter { $0.ownerDigest == owner.digest } }
        }
    }
    private final class Clock: Sendable {
        private let locked = OSAllocatedUnfairLock<Date>(initialState: NativeCertificateCreationTests.now)
        var now: Date { locked.withLock { $0 } }
        func advance(by interval: TimeInterval) { locked.withLock { $0 = $0.addingTimeInterval(interval) } }
    }
    private actor Calls {
        private var downloads = 0
        func downloadedProfile() { downloads += 1 }
        func downloadCount() -> Int { downloads }
        private var profilePause = false
        private var profileEntered = false
        private var profileEntry: CheckedContinuation<Void, Never>?
        private var profileRelease: CheckedContinuation<Void, Never>?
        func pauseProfileRead() { profilePause = true }
        func profileRead() async {
            guard profilePause else { return }
            profileEntered = true; profileEntry?.resume(); profileEntry = nil
            await withCheckedContinuation { profileRelease = $0 }
        }
        func waitForProfileRead() async {
            if profileEntered { return }
            await withCheckedContinuation { profileEntry = $0 }
        }
        func releaseProfileRead() {
            profilePause = false; profileEntered = true
            profileEntry?.resume(); profileEntry = nil
            profileRelease?.resume(); profileRelease = nil
        }
        var sends = 0
        var registrationSends = 0
        var registrationIntentObserved = false
        private var pause = false
        private var entered = false
        private var entryWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func pauseRegistration() { pause = true }
        func waitForRegistration() async {
            if entered { return }
            await withCheckedContinuation { entryWaiter = $0 }
        }
        func releaseRegistration() {
            pause = false; entered = true
            entryWaiter?.resume(); entryWaiter = nil
            releaseWaiter?.resume(); releaseWaiter = nil
        }
        func registered(intent: Bool) async {
            registrationSends += 1; registrationIntentObserved = intent; entered = true
            entryWaiter?.resume(); entryWaiter = nil
            if pause { await withCheckedContinuation { releaseWaiter = $0 } }
        }
        func registrationValues() -> (Int, Bool) { (registrationSends, registrationIntentObserved) }
        var inventory = 0
        var observedUncertain = false
        func sent(uncertain: Bool) { sends += 1; observedUncertain = uncertain }
        func listed() { inventory += 1 }
        func values() -> (Int, Int, Bool) { (sends, inventory, observedUncertain) }
    }
    private struct Store: AppleAccountRecoverableSessionStorage, AppleAccountResumeJournalStorage {
        struct State: Sendable {
            var journal: AppleAccountResumeJournal?
            var data: [UUID: Data] = [:]
        }
        let lock = OSAllocatedUnfairLock(initialState: State())
        func readJournal() -> AppleAccountResumeJournal? { lock.withLock { $0.journal } }
        func writeJournal(_ journal: AppleAccountResumeJournal) { lock.withLock { $0.journal = journal } }
        func readSession(reference: UUID) -> Data? { lock.withLock { $0.data[reference] } }
        func insertSession(_ sessionData: Data, reference: UUID) -> UUID {
            lock.withLock { $0.data[reference] = sessionData }; return reference
        }
        func deleteSession(reference: UUID) { lock.withLock { _ = $0.data.removeValue(forKey: reference) } }
    }
    private struct Provider: ConsentedAnisetteProvider {
        let descriptor: AnisetteProviderDescriptor
        func freshHeaders() async throws -> AnisetteData { NativeCertificateCreationTests.headers() }
    }
    private struct Portal: SideSignPreparedCSRPortal, SideSignProfileTransport {
        let vault: Vault
        let calls: Calls
        let failSend: Bool
        let registrations: RegistrationStore
        let downloadCMS: Data?
        func registrationInventory(subject: NativeRegistrationSubject, team: Team, session: Session) async throws -> [NativeRegistrationObservation] {
            await calls.profileRead()
            let values = await calls.registrationValues()
            guard values.0 > 0 else { return [] }
            return [.init(subject: subject, remoteIdentifier: "REMOTE1", enabled: true, expiresAt: nil)]
        }
        func registerSubjectOnce(_ subject: NativeRegistrationSubject, operationID: UUID, team: Team, session: Session) async throws {
            let observed = registrations.lock.withLock { $0?.id == operationID && $0?.phase == .uncertain }
            await calls.registered(intent: observed)
            if failSend { throw URLError(.timedOut) }
        }
        func downloadProvisioningProfile(encodedSession: Data, headers: AnisetteData, teamIdentifier: String,
                                         profileUUID: UUID, now: Date) async throws -> Data {
            guard let downloadCMS else {
                XCTFail("Default CMS gate must prevent profile download")
                throw NativeProfileCreationError.inventoryRejected
            }
            await calls.downloadedProfile()
            return downloadCMS
        }
        func profileCertificateInventory(team: Team, session: Session) async throws -> [NativeProfileCertificateObservation] {
            XCTFail("Default CMS gate must prevent certificate I/O"); return []
        }
        func profileInventory(request: NativeProfileCreationRequest, team: Team, session: Session,
                              checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> [NativeProfileObservation] {
            XCTFail("Default CMS gate must prevent profile I/O"); return []
        }
        func createLimitedProfileOnce(request: NativeProfileCreationRequest, operationID: UUID, team: Team, session: Session) async throws {
            XCTFail("Default CMS gate must prevent profile creation")
        }
        func authenticate(appleID: String, password: String, anisetteData: AnisetteData,
                          xcodeVersion: String, machinePassword: String?,
                          accountRepairHandler: DeveloperPortal.AccountRepairHandler,
                          verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> AuthSession {
            NativeCertificateCreationTests.session()
        }
        func fetchAccount(session: Session) async throws -> Account { NativeCertificateCreationTests.session().account }
        func fetchTeams(for account: Account, session: Session) async throws -> [Team] { [.init(identifier: "ABCDE12345", name: "Fixture", type: .free)] }
        func fetchDevices(for team: Team, types: DeviceType, session: Session) async throws -> [Device] { [] }
        func fetchAppIDs(for team: Team, session: Session) async throws -> [AppID] { [] }
        func fetchCertificates(for team: Team, session: Session) async throws -> [X509Certificate] { await calls.listed(); return [] }
        func submitPreparedDevelopmentCSR(_ submission: NativeSigningCSRSubmission, team: Team,
                                          session: Session) async throws -> NativeSigningCertificateObservation? {
            let phase = await vault.currentPhase()
            await calls.sent(uncertain: phase == .submissionUncertain)
            if failSend { throw URLError(.timedOut) }
            return nil // forces READ-ONLY inventory recovery, never a second send
        }
    }
    private typealias Bridge = SideSignAccountBridge<Portal, Provider, Store, Store>
    private static func headers() -> AnisetteData {
        .init(machineID: "fixture", oneTimePassword: "fixture", localUserID: "fixture", routingInfo: "1",
              deviceID: "fixture", serialNumber: "fixture", clientInfo: "fixture", userAgent: "fixture",
              clientTime: "fixture", locale: "en_US", timeZone: "UTC")
    }
    private static func session() -> AuthSession {
        .init(account: .init(appleID: "fixture@example.invalid", identifier: "123"),
              session: .init(dsid: "123", authToken: "SYNTHETIC", anisetteData: headers(), xcodeVersion: "26.2",
                             creationDate: now.addingTimeInterval(-10), expirationDate: now.addingTimeInterval(600)))
    }
    private static func fixture(failSend: Bool = false, phase: NativeSigningIdentityPhase = .prepared,
                                profileValidator: NativeProvisioningProfileValidator = .init(),
                                exportFixture: Bool = false, receipts: (any NativeProfileReceiptStorage)? = nil,
                                downloadCMS: Data? = nil, clock suppliedClock: Clock? = nil) async throws -> (Bridge, Vault, Calls, UUID, AnisetteConsentToken) {
        let vault = Vault(phase: phase, exportFixture: exportFixture); let calls = Calls(); let store = Store()
        let registrations = RegistrationStore()
        let portal = Portal(vault: vault, calls: calls, failSend: failSend, registrations: registrations, downloadCMS: downloadCMS)
        let clock = suppliedClock ?? Clock()
        let descriptor = try AnisetteProviderDescriptor(identifier: "fixture", displayName: "Fixture", policyRevision: "1", endpoint: nil)
        let bridge = Bridge(adapter: SideSignAccountAdapter(portal: portal, clock: { clock.now }),
            provider: Provider(descriptor: descriptor), sessions: store, journal: store, clock: { clock.now }, lifetime: Lifetime(), identities: vault, registrations: registrations, profiles: ProfileStore(), receipts: receipts, profileValidator: profileValidator)
        let consent = try await bridge.recordExplicitAnisetteConsent()
        let handle = try await bridge.startAuthentication(appleID: "fixture@example.invalid", password: "SYNTHETIC", xcodeVersion: "26.2", consent: consent)
        await handle.waitUntilFinished()
        _ = try await bridge.selectTeam(identifier: "ABCDE12345", operation: handle.operation)
        let snapshot = await bridge.snapshot()
        guard case .signedIn(let context) = snapshot.phase else { throw NativeSigningIdentityError.contextChanged }
        return (bridge, vault, calls, context.id, consent)
    }

    private static let exportBundle = "com.example.fixture"
    private static let exportUDID = "0000ABCD-0011223344556677"
    private static let exportCMS = Data("SYNTHETIC EXPORT CMS".utf8)

    private static func exportValidator(profileUUID: UUID) throws -> NativeProvisioningProfileValidator {
        let root: [String: Any] = ["Version": 1, "UUID": profileUUID.uuidString,
            "CreationDate": now.addingTimeInterval(-60), "ExpirationDate": now.addingTimeInterval(3600), "Platform": ["iOS"],
            "TeamIdentifier": ["ABCDE12345"], "ApplicationIdentifierPrefix": ["ABCDE12345"],
            "ProvisionedDevices": [exportUDID], "DeveloperCertificates": [Data([1])],
            "Entitlements": ["application-identifier": "ABCDE12345." + exportBundle,
                "com.apple.developer.team-identifier": "ABCDE12345", "get-task-allow": true,
                "keychain-access-groups": ["ABCDE12345.*"]]]
        let payload = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        return NativeProvisioningProfileValidator(verifier: ExportVerifier(payload: payload))
    }

    private static func exportReceipt(identityID: UUID, profileUUID: UUID,
                                      validator: NativeProvisioningProfileValidator) async throws -> NativeProfileReceipt {
        let owner = try NativeSigningIdentityOwner(accountIdentifier: "123", dsid: "123", teamIdentifier: "ABCDE12345")
        let validation = try NativeProfileValidationRequest(teamIdentifier: "ABCDE12345",
            bundleIdentifier: exportBundle, deviceIdentifier: exportUDID, certificateDER: Data([1]))
        let request = try NativeProfileCreationRequest(identityID: identityID, validation: validation,
            appID: "APP1", deviceID: "DEVICE1", certificateID: "CERT1")
        let profile = try await validator.validate(cms: exportCMS, request: validation, now: now)
        return try NativeProfileReceipt(profile: profile, owner: owner, request: request, recordedAt: now)
    }

    func testProfileExportReturnsExactFreshlyValidatedCMSBytes() async throws {
        let profileUUID = UUID()
        let validator = try Self.exportValidator(profileUUID: profileUUID)
        let receipts = ReceiptStore()
        let (bridge, vault, calls, context, consent) = try await Self.fixture(phase: .certificateRecorded,
            profileValidator: validator, receipts: receipts, downloadCMS: Self.exportCMS)
        let identityID = await vault.identityID
        let receipt = try await Self.exportReceipt(identityID: identityID, profileUUID: profileUUID, validator: validator)
        try receipts.record(receipt,
                            owner: NativeSigningIdentityOwner(accountIdentifier: "123", dsid: "123", teamIdentifier: "ABCDE12345"))
        let exported = try await bridge.exportProvisioningProfile(contextID: context, profileUUID: profileUUID,
            identityID: identityID, bundleIdentifier: Self.exportBundle, deviceIdentifier: Self.exportUDID, consent: consent)
        XCTAssertEqual(exported, Self.exportCMS)
        let downloads = await calls.downloadCount()
        XCTAssertEqual(downloads, 1)
        await bridge.shutdown()
    }

    func testProfileExportRequiresCurrentReceiptBeforePortalDownload() async throws {
        let profileUUID = UUID()
        let validator = try Self.exportValidator(profileUUID: profileUUID)
        let (bridge, vault, calls, context, consent) = try await Self.fixture(phase: .certificateRecorded,
            profileValidator: validator, receipts: ReceiptStore(), downloadCMS: Self.exportCMS)
        do {
            _ = try await bridge.exportProvisioningProfile(contextID: context, profileUUID: profileUUID,
                identityID: await vault.identityID, bundleIdentifier: Self.exportBundle,
                deviceIdentifier: Self.exportUDID, consent: consent)
            XCTFail("A profile without an authenticated receipt must not be exported")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .receiptUnavailable) }
        let downloads = await calls.downloadCount()
        XCTAssertEqual(downloads, 0)
        await bridge.shutdown()
    }

    func testProfileExportRejectsDigestSubstitutionAfterDownload() async throws {
        let profileUUID = UUID()
        let validator = try Self.exportValidator(profileUUID: profileUUID)
        let receipts = ReceiptStore()
        let (bridge, vault, calls, context, consent) = try await Self.fixture(phase: .certificateRecorded,
            profileValidator: validator, receipts: receipts, downloadCMS: Data("SUBSTITUTED CMS".utf8))
        let identityID = await vault.identityID
        let receipt = try await Self.exportReceipt(identityID: identityID, profileUUID: profileUUID, validator: validator)
        try receipts.record(receipt,
                            owner: NativeSigningIdentityOwner(accountIdentifier: "123", dsid: "123", teamIdentifier: "ABCDE12345"))
        do {
            _ = try await bridge.exportProvisioningProfile(contextID: context, profileUUID: profileUUID,
                identityID: identityID, bundleIdentifier: Self.exportBundle, deviceIdentifier: Self.exportUDID, consent: consent)
            XCTFail("The returned CMS must match the authenticated receipt")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .receiptMismatch) }
        let downloads = await calls.downloadCount()
        XCTAssertEqual(downloads, 1)
        await bridge.shutdown()
    }

    func testProfileExportRejectsExpiredConsentBeforePortalDownload() async throws {
        let profileUUID = UUID()
        let validator = try Self.exportValidator(profileUUID: profileUUID)
        let receipts = ReceiptStore(); let clock = Clock()
        let (bridge, vault, calls, context, consent) = try await Self.fixture(phase: .certificateRecorded,
            profileValidator: validator, receipts: receipts, downloadCMS: Self.exportCMS, clock: clock)
        let identityID = await vault.identityID
        let receipt = try await Self.exportReceipt(identityID: identityID, profileUUID: profileUUID, validator: validator)
        try receipts.record(receipt,
                            owner: NativeSigningIdentityOwner(accountIdentifier: "123", dsid: "123", teamIdentifier: "ABCDE12345"))
        clock.advance(by: 901)
        do {
            _ = try await bridge.exportProvisioningProfile(contextID: context, profileUUID: profileUUID,
                identityID: identityID, bundleIdentifier: Self.exportBundle, deviceIdentifier: Self.exportUDID, consent: consent)
            XCTFail("Expired consent must fail closed")
        } catch { XCTAssertEqual(error as? AnisetteConsentError, .consentRequired) }
        let downloads = await calls.downloadCount()
        XCTAssertEqual(downloads, 0)
        await bridge.shutdown()
    }

    func testFailedExportConsumesGrantBeforePrivateKeyReadAndReplay() async throws {
        let (bridge, vault, _, context, _) = try await Self.fixture(phase: .certificateRecorded, exportFixture: true)
        let id = await vault.identityID
        let grant = try await bridge.recordExplicitKeyExportConsent(contextID: context, identityID: id)
        do {
            _ = try await bridge.exportSigningIdentity(contextID: context, identityID: id, password: "synthetic", consent: grant)
            XCTFail("Synthetic key read deliberately fails")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .generationFailed) }
        do {
            _ = try await bridge.exportSigningIdentity(contextID: context, identityID: id, password: "synthetic", consent: grant)
            XCTFail("Failed export must require fresh explicit approval")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .creationApprovalRequired) }
        let reads = await vault.privateKeyReadCount()
        XCTAssertEqual(reads, 1)
        await bridge.shutdown()
    }

    func testRevokedExportGrantNeverReachesPrivateKeyRead() async throws {
        let (bridge, vault, _, context, _) = try await Self.fixture(phase: .certificateRecorded, exportFixture: true)
        let id = await vault.identityID
        let grant = try await bridge.recordExplicitKeyExportConsent(contextID: context, identityID: id)
        await bridge.revokeKeyExportConsent()
        do {
            _ = try await bridge.exportSigningIdentity(contextID: context, identityID: id, password: "synthetic", consent: grant)
            XCTFail("Revoked consent must fail before private key access")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .creationApprovalRequired) }
        let reads = await vault.privateKeyReadCount()
        XCTAssertEqual(reads, 0)
        await bridge.shutdown()
    }

    func testAnisetteConsentAloneCannotAuthorizeMutation() async throws {
        let (bridge, vault, calls, context, consent) = try await Self.fixture()
        let id = await vault.identityID
        let unminted = NativeCertificateCreationApproval(id: UUID(), contextID: context, identityID: id,
                                                        flow: UUID(), epoch: UUID(), expiresAt: Self.now.addingTimeInterval(60))
        do {
            _ = try await bridge.createDevelopmentSigningCertificate(contextID: context, identityID: id, approval: unminted, consent: consent)
            XCTFail("User mutation approval required")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .creationApprovalRequired) }
        let values = await calls.values(); XCTAssertEqual(values.0, 0)
        await bridge.shutdown()
    }

    func testIntentPrecedesSendAndMissingReceiptUsesInventoryWithoutResubmit() async throws {
        let (bridge, vault, calls, context, consent) = try await Self.fixture()
        let id = await vault.identityID
        let approval = try await bridge.recordExplicitCertificateCreationApproval(contextID: context, identityID: id)
        let result = try await bridge.createDevelopmentSigningCertificate(contextID: context, identityID: id, approval: approval, consent: consent)
        XCTAssertEqual(result.phase, .certificateRecorded)
        let values = await calls.values(); XCTAssertEqual(values.0, 1); XCTAssertEqual(values.1, 1); XCTAssertTrue(values.2)
        do {
            _ = try await bridge.createDevelopmentSigningCertificate(contextID: context, identityID: id, approval: approval, consent: consent)
            XCTFail("Single-use approval")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .creationApprovalRequired) }
        await bridge.shutdown()
    }

    func testFailedSendKeepsUncertainIdentityAndRejectsNewCreationApproval() async throws {
        let (bridge, vault, calls, context, consent) = try await Self.fixture(failSend: true)
        let id = await vault.identityID
        let approval = try await bridge.recordExplicitCertificateCreationApproval(contextID: context, identityID: id)
        do { _ = try await bridge.createDevelopmentSigningCertificate(contextID: context, identityID: id, approval: approval, consent: consent); XCTFail("Timeout") }
        catch { XCTAssertEqual(error as? NativeSigningIdentityError, .certificateRequestFailed) }
        let phase = await vault.currentPhase(); XCTAssertEqual(phase, .submissionUncertain)
        do { _ = try await bridge.recordExplicitCertificateCreationApproval(contextID: context, identityID: id); XCTFail("No reissue") }
        catch { XCTAssertEqual(error as? NativeSigningIdentityError, .reconciliationRequired) }
        let values = await calls.values(); XCTAssertEqual(values.0, 1)
        await bridge.shutdown()
    }

    func testExplicitReconciliationNeverInvokesCSRSubmission() async throws {
        let (bridge, vault, calls, context, consent) = try await Self.fixture(phase: .submissionUncertain)
        let id = await vault.identityID
        _ = try await bridge.reconcileUncertainSigningCertificate(contextID: context, identityID: id, consent: consent)
        let values = await calls.values(); XCTAssertEqual(values.0, 0); XCTAssertEqual(values.1, 1)
        await bridge.shutdown()
    }

    func testRevokedApprovalCannotStartSend() async throws {
        let (bridge, vault, calls, context, consent) = try await Self.fixture()
        let id = await vault.identityID
        let approval = try await bridge.recordExplicitCertificateCreationApproval(contextID: context, identityID: id)
        await bridge.revokeCertificateCreationApproval()
        do {
            _ = try await bridge.createDevelopmentSigningCertificate(contextID: context, identityID: id, approval: approval, consent: consent)
            XCTFail("Revoked")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .creationApprovalRequired) }
        let values = await calls.values(); XCTAssertEqual(values.0, 0)
        await bridge.shutdown()
    }

    func testApprovalLifetimeRejectsUnboundedValues() async throws {
        let (bridge, vault, _, context, _) = try await Self.fixture()
        let id = await vault.identityID
        for lifetime in [Double.nan, Double.infinity, 0, 121] {
            do { _ = try await bridge.recordExplicitCertificateCreationApproval(contextID: context, identityID: id, lifetime: lifetime); XCTFail("Bound lifetime") }
            catch { XCTAssertEqual(error as? NativeSigningIdentityError, .creationApprovalRequired) }
        }
        await bridge.shutdown()
    }
    func testRegistrationApprovalIsSeparateAndSingleUse() async throws {
        let (bridge, _, calls, context, consent) = try await Self.fixture()
        let subject = try NativeRegistrationSubject(kind: .appID, value: "com.example.fixture")
        let grant = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject)
        let result = try await bridge.registerAccountResource(contextID: context, subject: subject, approval: grant, consent: consent)
        XCTAssertNotNil(result.operationID)
        let values = await calls.registrationValues(); XCTAssertEqual(values.0, 1); XCTAssertTrue(values.1)
        do { _ = try await bridge.registerAccountResource(contextID: context, subject: subject, approval: grant, consent: consent); XCTFail("Single use") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .approvalRequired) }
        await bridge.shutdown()
    }

    func testRegistrationWrongSubjectCannotUseGrant() async throws {
        let (bridge, _, calls, context, consent) = try await Self.fixture()
        let subject = try NativeRegistrationSubject(kind: .appID, value: "com.example.fixture")
        let other = try NativeRegistrationSubject(kind: .appID, value: "com.example.other")
        let grant = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject)
        do { _ = try await bridge.registerAccountResource(contextID: context, subject: other, approval: grant, consent: consent); XCTFail("Exact subject required") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .approvalRequired) }
        let values = await calls.registrationValues(); XCTAssertEqual(values.0, 0)
        await bridge.shutdown()
    }

    func testRegistrationRevokedApprovalCannotSubmit() async throws {
        let (bridge, _, calls, context, consent) = try await Self.fixture()
        let subject = try NativeRegistrationSubject(kind: .device, value: "0000ABCD-0011223344556677")
        let grant = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject)
        await bridge.revokeRegistrationApproval()
        do { _ = try await bridge.registerAccountResource(contextID: context, subject: subject, approval: grant, consent: consent); XCTFail("Revoked") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .approvalRequired) }
        let values = await calls.registrationValues(); XCTAssertEqual(values.0, 0)
        await bridge.shutdown()
    }

    func testRegistrationTimeoutRecoversWithoutAnotherSend() async throws {
        let (bridge, _, calls, context, consent) = try await Self.fixture(failSend: true)
        let subject = try NativeRegistrationSubject(kind: .appID, value: "com.example.fixture")
        let grant = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject)
        do { _ = try await bridge.registerAccountResource(contextID: context, subject: subject, approval: grant, consent: consent); XCTFail("Timeout") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .requestFailed) }
        do { _ = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject); XCTFail("Retain uncertainty") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .reconciliationRequired) }
        let result = try await bridge.reconcileAccountRegistration(contextID: context, subject: subject, consent: consent)
        XCTAssertNotNil(result.operationID)
        let values = await calls.registrationValues(); XCTAssertEqual(values.0, 1)
        await bridge.shutdown()
    }

    func testRegistrationSignOutInvalidatesPendingApproval() async throws {
        let (bridge, _, calls, context, consent) = try await Self.fixture()
        let subject = try NativeRegistrationSubject(kind: .appID, value: "com.example.fixture")
        let grant = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject)
        try await bridge.signOut()
        do { _ = try await bridge.registerAccountResource(contextID: context, subject: subject, approval: grant, consent: consent); XCTFail("Signed out") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .approvalRequired) }
        let values = await calls.registrationValues(); XCTAssertEqual(values.0, 0)
        await bridge.shutdown()
    }

    func testRegistrationSharesIdentityAndConsentBusyGate() async throws {
        let (bridge, _, calls, context, consent) = try await Self.fixture()
        let subject = try NativeRegistrationSubject(kind: .appID, value: "com.example.fixture")
        let grant = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject)
        await calls.pauseRegistration()
        let operation = Task {
            do { return try await bridge.registerAccountResource(contextID: context, subject: subject, approval: grant, consent: consent) }
            catch { await calls.releaseRegistration(); throw error }
        }
        await calls.waitForRegistration()
        do { _ = try await bridge.prepareSigningIdentity(contextID: context); XCTFail("Exclusive account work") }
        catch { XCTAssertEqual(error as? NativeSigningIdentityError, .busy) }
        do { _ = try await bridge.recordExplicitAnisetteConsent(); XCTFail("No consent replacement during mutation") }
        catch { XCTAssertEqual(error as? Bridge.Failure, .flowBusy) }
        await calls.releaseRegistration()
        _ = try await operation.value
        await bridge.shutdown()
    }

    func testRegistrationSignOutCancelsButHoldsSlotUntilWorkerRetires() async throws {
        let (bridge, _, calls, context, consent) = try await Self.fixture()
        let subject = try NativeRegistrationSubject(kind: .appID, value: "com.example.fixture")
        let grant = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject)
        await calls.pauseRegistration()
        let operation = Task {
            do { return try await bridge.registerAccountResource(contextID: context, subject: subject, approval: grant, consent: consent) }
            catch { await calls.releaseRegistration(); throw error }
        }
        await calls.waitForRegistration()
        try await bridge.signOut()
        do { _ = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject); XCTFail("Worker still retained") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .busy) }
        await calls.releaseRegistration()
        do { _ = try await operation.value; XCTFail("Cancelled worker") }
        catch { XCTAssertTrue(error is CancellationError) }
        let values = await calls.registrationValues(); XCTAssertEqual(values.0, 1)
        await bridge.shutdown()
    }

    func testBoundProfileDefaultVerifierBlocksBeforeSessionAndCallbacks() throws {
        let portal = Portal(vault: Vault(), calls: Calls(), failSend: false, registrations: RegistrationStore(), downloadCMS: nil)
        let owner = try NativeSigningIdentityOwner(accountIdentifier: "123", dsid: "123", teamIdentifier: "ABCDE12345")
        let validation = try NativeProfileValidationRequest(teamIdentifier: owner.teamIdentifier, bundleIdentifier: "com.example.fixture",
            deviceIdentifier: "0000ABCD-0011223344556677", certificateDER: Data([1]))
        let request = try NativeProfileCreationRequest(identityID: UUID(), validation: validation, appID: "APP1", deviceID: "DEVICE1", certificateID: "CERT1")
        do {
            _ = try SideSignBoundProfilePortal(portal: portal, owner: owner, contextID: UUID(), request: request,
                encodedSession: Data(), authorityExpiresAt: Self.now.addingTimeInterval(60), lifetime: Lifetime(),
                freshHeaders: { XCTFail("No provider callback before CMS availability"); throw NativeProfileCreationError.requestFailed },
                ownedIdentity: { XCTFail("No vault callback before CMS availability"); throw NativeProfileCreationError.requestFailed },
                checkCurrent: { XCTFail("No authority callback before CMS availability") }, clock: { Self.now })
            XCTFail("Missing verifier")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsVerificationUnavailable) }
    }

    func testProfileApprovalDefaultCMSGateBlocksOwnedIdentityProjection() async throws {
        let (bridge, vault, _, context, _) = try await Self.fixture()
        let id = await vault.identityID
        let target = try NativeAccountProfileTarget(identityID: id, bundleIdentifier: "com.example.fixture",
            deviceIdentifier: "0000ABCD-0011223344556677", registeredAppID: "APP1", registeredDeviceID: "DEVICE1")
        do {
            _ = try await bridge.recordExplicitProfileCreationApproval(contextID: context, target: target)
            XCTFail("No default verifier")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsVerificationUnavailable) }
        // Prepared vault cannot project an owned recorded certificate. Reaching
        // it would throw reconciliationRequired, so this also checks ordering.
        await bridge.shutdown()
    }

    func testProfileRecoveryDefaultCMSGateBlocksProviderAndPortal() async throws {
        let (bridge, vault, calls, context, consent) = try await Self.fixture()
        let id = await vault.identityID
        let target = try NativeAccountProfileTarget(identityID: id, bundleIdentifier: "com.example.fixture",
            deviceIdentifier: "0000ABCD-0011223344556677", registeredAppID: "APP1", registeredDeviceID: "DEVICE1", selectedProfileUUID: UUID())
        do {
            _ = try await bridge.reconcileAccountProvisioningProfile(contextID: context, target: target, consent: consent)
            XCTFail("No default verifier")
        } catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsVerificationUnavailable) }
        let values = await calls.values(); XCTAssertEqual(values.0, 0); XCTAssertEqual(values.1, 0)
        await bridge.shutdown()
    }

    func testUnmintedProfileApprovalCannotAuthorizeMutation() async throws {
        let (bridge, vault, calls, context, consent) = try await Self.fixture()
        let id = await vault.identityID
        let target = try NativeAccountProfileTarget(identityID: id, bundleIdentifier: "com.example.fixture",
            deviceIdentifier: "0000ABCD-0011223344556677", registeredAppID: "APP1", registeredDeviceID: "DEVICE1")
        let unminted = NativeAccountProfileApproval(id: UUID(), contextID: context, ownerDigest: "fixture",
            targetDigest: target.approvalDigest, requestDigest: "fixture", flow: UUID(), epoch: UUID(), expiresAt: Self.now.addingTimeInterval(60))
        do {
            _ = try await bridge.createAccountProvisioningProfile(contextID: context, target: target, approval: unminted, consent: consent)
            XCTFail("Stored user approval required")
        } catch { XCTAssertEqual(error as? NativeProfileCreationError, .approvalRequired) }
        let values = await calls.values(); XCTAssertEqual(values.0, 0)
        await bridge.shutdown()
    }

    private static func profileTarget(_ id: UUID, app: String = "APP1", selected: UUID? = nil) throws -> NativeAccountProfileTarget {
        try .init(identityID: id, bundleIdentifier: "com.example.fixture", deviceIdentifier: "0000ABCD-0011223344556677",
                  registeredAppID: app, registeredDeviceID: "DEVICE1", selectedProfileUUID: selected)
    }

    func testConsumedProfileGrantCannotRetryAfterFreshResourceRejection() async throws {
        let (bridge, vault, _, context, consent) = try await Self.fixture(phase: .certificateRecorded, profileValidator: .init(verifier: RejectionVerifier()))
        let id = await vault.identityID; let target = try Self.profileTarget(id)
        let grant = try await bridge.recordExplicitProfileCreationApproval(contextID: context, target: target)
        do {
            _ = try await bridge.createAccountProvisioningProfile(contextID: context, target: target, approval: grant, consent: consent)
            XCTFail("Absent exact device must reject before intent or CMS")
        } catch { XCTAssertEqual(error as? NativeProfileCreationError, .inventoryRejected) }
        do {
            _ = try await bridge.createAccountProvisioningProfile(contextID: context, target: target, approval: grant, consent: consent)
            XCTFail("Grant consumed even before intent")
        } catch { XCTAssertEqual(error as? NativeProfileCreationError, .approvalRequired) }
        await bridge.shutdown()
    }

    func testRevokedProfileGrantCannotExecute() async throws {
        let (bridge, vault, _, context, consent) = try await Self.fixture(phase: .certificateRecorded, profileValidator: .init(verifier: RejectionVerifier()))
        let id = await vault.identityID; let target = try Self.profileTarget(id)
        let grant = try await bridge.recordExplicitProfileCreationApproval(contextID: context, target: target)
        await bridge.revokeProfileCreationApproval()
        do {
            _ = try await bridge.createAccountProvisioningProfile(contextID: context, target: target, approval: grant, consent: consent)
            XCTFail("Revoked grant")
        } catch { XCTAssertEqual(error as? NativeProfileCreationError, .approvalRequired) }
        await bridge.shutdown()
    }

    func testProfileGrantCannotChangeRemoteTarget() async throws {
        let (bridge, vault, _, context, consent) = try await Self.fixture(phase: .certificateRecorded, profileValidator: .init(verifier: RejectionVerifier()))
        let id = await vault.identityID; let target = try Self.profileTarget(id)
        let grant = try await bridge.recordExplicitProfileCreationApproval(contextID: context, target: target)
        do {
            _ = try await bridge.createAccountProvisioningProfile(contextID: context, target: Self.profileTarget(id, app: "APP2"), approval: grant, consent: consent)
            XCTFail("Exact target approval required")
        } catch { XCTAssertEqual(error as? NativeProfileCreationError, .approvalRequired) }
        await bridge.shutdown()
    }

    func testSelectedExistingProfileUUIDCannotMintCreationGrant() async throws {
        let (bridge, vault, _, context, _) = try await Self.fixture(phase: .certificateRecorded, profileValidator: .init(verifier: RejectionVerifier()))
        let id = await vault.identityID
        do {
            _ = try await bridge.recordExplicitProfileCreationApproval(contextID: context, target: Self.profileTarget(id, selected: UUID()))
            XCTFail("Selected UUID is recovery-only")
        } catch { XCTAssertEqual(error as? NativeProfileCreationError, .approvalRequired) }
        await bridge.shutdown()
    }

    func testCancelledProfileWorkerRetainsSharedSlotUntilActualRetirement() async throws {
        let (bridge, vault, calls, context, consent) = try await Self.fixture(phase: .certificateRecorded, profileValidator: .init(verifier: RejectionVerifier()))
        let id = await vault.identityID; let target = try Self.profileTarget(id)
        let grant = try await bridge.recordExplicitProfileCreationApproval(contextID: context, target: target)
        await calls.pauseProfileRead()
        let operation = Task {
            do { return try await bridge.createAccountProvisioningProfile(contextID: context, target: target, approval: grant, consent: consent) }
            catch { await calls.releaseProfileRead(); throw error }
        }
        await calls.waitForProfileRead()
        await bridge.revokeProfileCreationApproval()
        do { _ = try await bridge.prepareSigningIdentity(contextID: context); XCTFail("Worker retained") }
        catch { XCTAssertEqual(error as? NativeSigningIdentityError, .busy) }
        let subject = try NativeRegistrationSubject(kind: .appID, value: "com.example.other")
        do { _ = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject); XCTFail("Shared slot retained") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .busy) }
        await calls.releaseProfileRead()
        do { _ = try await operation.value; XCTFail("Cancelled worker") }
        catch { XCTAssertTrue(error is CancellationError) }
        await bridge.shutdown()
    }

    func testStatusConsentRequiresDurableOwnedCertificateNotJustSignedInAccount() async throws {
        let (bridge, vault, calls, context, _) = try await Self.fixture()
        let id = await vault.identityID
        do {
            _ = try await bridge.recordExplicitCertificateStatusConsent(contextID: context, identityID: id)
            XCTFail("No usable recorded owned certificate in fixture")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .reconciliationRequired) }
        let values = await calls.values(); XCTAssertEqual(values.0, 0)
        await bridge.shutdown()
    }

    func testCancelledStatusWorkerRetainsSharedSlotUntilOwnershipReadRetires() async throws {
        let (bridge, vault, _, context, _) = try await Self.fixture()
        let id = await vault.identityID
        await vault.pauseOwnedStatus()
        let operation = Task {
            do { return try await bridge.evaluateSigningCertificateStatus(contextID: context, identityID: id) }
            catch { await vault.releaseOwnedStatus(); throw error }
        }
        await vault.waitOwnedStatus()
        await bridge.revokeCertificateStatusConsent()
        do { _ = try await bridge.prepareSigningIdentity(contextID: context); XCTFail("Status worker retained") }
        catch { XCTAssertEqual(error as? NativeSigningIdentityError, .busy) }
        let subject = try NativeRegistrationSubject(kind: .appID, value: "com.example.other")
        do { _ = try await bridge.recordExplicitRegistrationApproval(contextID: context, subject: subject); XCTFail("Shared slot retained") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .busy) }
        await vault.releaseOwnedStatus()
        do { _ = try await operation.value; XCTFail("Cancelled worker") }
        catch { XCTAssertTrue(error is CancellationError) }
        await bridge.shutdown()
    }

}
