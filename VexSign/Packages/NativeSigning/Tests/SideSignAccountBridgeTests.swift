import Foundation
import XCTest
import SideSign
import os
@testable import NativeSigningLinkSmoke

final class SideSignAccountBridgeTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private actor Gate {
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var blocked: CheckedContinuation<Void, Never>?
        func pause() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters = []
            guard !released else { return }
            await withCheckedContinuation { blocked = $0 }
        }
        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }
        func release() { released = true; blocked?.resume(); blocked = nil }
    }
    private actor Calls {
        private var values = [0, 0, 0, 0] // provider, login, account, teams
        func record(_ index: Int) { values[index] += 1 }
        func counts() -> [Int] { values }
    }
    private struct Store: AppleAccountRecoverableSessionStorage, AppleAccountResumeJournalStorage {
        struct State: Sendable {
            var journal: AppleAccountResumeJournal?
            var items: [UUID: Data] = [:]
            var insertions = 0
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())
        var state: State { lock.withLock { $0 } }
        func readJournal() throws -> AppleAccountResumeJournal? { lock.withLock { $0.journal } }
        func writeJournal(_ journal: AppleAccountResumeJournal) throws {
            try journal.validate()
            lock.withLock { $0.journal = journal }
        }
        func readSession(reference: UUID) throws -> Data? { lock.withLock { $0.items[reference] } }
        func insertSession(_ sessionData: Data, reference: UUID) throws -> UUID {
            lock.withLock {
                $0.items[reference] = sessionData
                $0.insertions += 1
            }
            return reference
        }
        func deleteSession(reference: UUID) throws { lock.withLock { $0.items.removeValue(forKey: reference) } }
    }
    private struct Provider: ConsentedAnisetteProvider {
        let descriptor: AnisetteProviderDescriptor
        let calls: Calls
        let gate: Gate?
        let fail: Bool
        func freshHeaders() async throws -> AnisetteData {
            await calls.record(0)
            await gate?.pause() // deliberately ignores cancellation for stale-work tests
            if fail { throw AnisetteConsentError.providerFailed }
            return SideSignAccountBridgeTests.headers()
        }
    }
    private struct Portal: SideSignAccountPortal {
        let calls: Calls
        let twoFactor: Bool
        let gate: Gate?
        let category: TeamType
        func authenticate(appleID: String, password: String, anisetteData: AnisetteData,
                          xcodeVersion: String, machinePassword: String?,
                          accountRepairHandler: DeveloperPortal.AccountRepairHandler,
                          verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> AuthSession {
            await calls.record(1)
            await gate?.pause() // deliberately returns even after cancellation
            if twoFactor {
                guard let handler = verificationHandler else { throw DeveloperPortalError.requiresTwoFactorAuthentication }
                let reply = try await handler(.trustedDevice(error: nil))
                guard case .verificationCode = reply else { throw DeveloperPortalError.userCancelled }
            }
            return SideSignAccountBridgeTests.session()
        }
        func fetchAccount(session: Session) async throws -> Account {
            await calls.record(2)
            return SideSignAccountBridgeTests.session().account
        }
        func fetchTeams(for account: Account, session: Session) async throws -> [Team] {
            await calls.record(3)
            return [Team(identifier: "TEAM", name: "Synthetic fixture", type: category)]
        }
    }
    private typealias Bridge = SideSignAccountBridge<Portal, Provider, Store, Store>
    private static func headers() -> AnisetteData {
        AnisetteData(machineID: "synthetic", oneTimePassword: "synthetic-otp", localUserID: "local", routingInfo: "route",
                     deviceID: "device", serialNumber: "serial", clientInfo: "client", userAgent: "agent", clientTime: "time", locale: "en_US", timeZone: "UTC")
    }
    private static func session() -> AuthSession {
        AuthSession(account: Account(appleID: "fixture@example.invalid", identifier: "123"),
                    session: Session(dsid: "123", authToken: "SYNTHETIC-TOKEN", anisetteData: headers(), xcodeVersion: "26.2",
                                     creationDate: now.addingTimeInterval(-10), expirationDate: now.addingTimeInterval(600)))
    }
    private static func bridge(store: Store, calls: Calls, providerGate: Gate? = nil,
                               portalGate: Gate? = nil, failProvider: Bool = false,
                               twoFactor: Bool = false, category: TeamType = .free,
                               lifetime: (any NativeAccountBackendLifetime)? = nil) throws -> Bridge {
        let descriptor = try AnisetteProviderDescriptor(identifier: "fixture", displayName: "Fixture", policyRevision: "1", endpoint: nil)
        let provider = Provider(descriptor: descriptor, calls: calls, gate: providerGate, fail: failProvider)
        let portal = Portal(calls: calls, twoFactor: twoFactor, gate: portalGate, category: category)
        let adapter = SideSignAccountAdapter(portal: portal, clock: { Self.now })
        return Bridge(adapter: adapter, provider: provider, sessions: store, journal: store, clock: { Self.now }, lifetime: lifetime)
    }
    private static func start(_ bridge: Bridge, token: AnisetteConsentToken) async throws -> Bridge.Handle {
        try await bridge.startAuthentication(appleID: "fixture@example.invalid", password: "SYNTHETIC-PASSWORD", xcodeVersion: "26.2", consent: token)
    }

    func testSDKResultIsDurablyCommittedBeforeExplicitTeamSelection() async throws {
        let store = Store()
        let calls = Calls()
        let bridge = try Self.bridge(store: store, calls: calls)
        var outcomes = await bridge.outcomes().makeAsyncIterator()
        let token = try await bridge.recordExplicitAnisetteConsent()
        let handle = try await Self.start(bridge, token: token)
        await handle.waitUntilFinished()
        let outcome = await outcomes.next()
        XCTAssertEqual(outcome, .awaitingTeamSelection(handle.operation))
        let snapshot = await bridge.snapshot()
        guard case .awaitingTeamSelection(_, let metadata) = snapshot.phase else { return XCTFail("Explicit team selection required") }
        XCTAssertEqual(store.state.journal?.selectedReference, metadata.credentialReference)
        XCTAssertEqual(store.state.items.count, 1)
        let selected = try await bridge.selectTeam(identifier: "TEAM", operation: handle.operation)
        XCTAssertTrue(selected)
    }

    func testForeignConsentCannotStartProviderOrAppleRequests() async throws {
        let store = Store()
        let calls = Calls()
        let bridge = try Self.bridge(store: store, calls: calls)
        let other = try Self.bridge(store: Store(), calls: Calls())
        let token = try await other.recordExplicitAnisetteConsent()
        do { _ = try await Self.start(bridge, token: token); XCTFail("Foreign grant must fail") }
        catch { XCTAssertEqual(error as? AnisetteConsentError, .consentRequired) }
        let counts = await calls.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0])
        XCTAssertTrue(store.state.items.isEmpty)
    }

    func testRevocationWhileProviderIgnoresCancellationPreventsAppleRequest() async throws {
        let store = Store()
        let calls = Calls()
        let gate = Gate()
        let bridge = try Self.bridge(store: store, calls: calls, providerGate: gate)
        let token = try await bridge.recordExplicitAnisetteConsent()
        let handle = try await Self.start(bridge, token: token)
        await gate.waitForEntry()
        await bridge.revokeAnisetteConsent()
        await gate.release()
        await handle.waitUntilFinished()
        let counts = await calls.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
        XCTAssertTrue(store.state.items.isEmpty)
        let snapshot = await bridge.snapshot()
        XCTAssertEqual(snapshot.phase, .signedOut)
    }

    func testRetryRejectsOldTwoFactorAndCommitsOnlyNewOperation() async throws {
        let store = Store()
        let bridge = try Self.bridge(store: store, calls: Calls(), twoFactor: true)
        let token = try await bridge.recordExplicitAnisetteConsent()
        let old = try await Self.start(bridge, token: token)
        var oldEvents = old.challenges.makeAsyncIterator()
        let oldEvent = await oldEvents.next()
        let previous = try XCTUnwrap(oldEvent)
        let current = try await Self.start(bridge, token: token)
        var currentEvents = current.challenges.makeAsyncIterator()
        let newEvent = await currentEvents.next()
        let challenge = try XCTUnwrap(newEvent)
        let stale = await bridge.submitTwoFactor(.verificationCode("123456"), operation: old.operation, challengeID: previous.id)
        XCTAssertFalse(stale)
        let snapshot = await bridge.snapshot()
        XCTAssertEqual(snapshot.phase, .awaitingTwoFactor(current.operation))
        let accepted = await bridge.submitTwoFactor(.verificationCode("123456"), operation: current.operation, challengeID: challenge.id)
        XCTAssertTrue(accepted)
        await old.waitUntilFinished()
        await current.waitUntilFinished()
        XCTAssertEqual(store.state.insertions, 1)
    }

    func testSignOutBeforeLateSDKReturnPreventsDurableCommit() async throws {
        let store = Store()
        let calls = Calls()
        let gate = Gate()
        let bridge = try Self.bridge(store: store, calls: calls, portalGate: gate)
        let token = try await bridge.recordExplicitAnisetteConsent()
        let handle = try await Self.start(bridge, token: token)
        await gate.waitForEntry()
        try await bridge.signOut()
        await gate.release()
        await handle.waitUntilFinished()
        XCTAssertTrue(store.state.items.isEmpty)
        XCTAssertEqual(store.state.insertions, 0)
        let counts = await calls.counts()
        XCTAssertEqual(counts, [1, 1, 0, 0])
    }

    func testRestartRevalidationKeepsRecordAndDoesNotApplySavedTeamHint() async throws {
        let store = Store()
        let calls = Calls()
        let previous = try Self.bridge(store: store, calls: calls)
        let token = try await previous.recordExplicitAnisetteConsent()
        let handle = try await Self.start(previous, token: token)
        await handle.waitUntilFinished()
        _ = try await previous.selectTeam(identifier: "TEAM", operation: handle.operation)
        let reference = store.state.journal?.selectedReference
        // Logical process recreation: the previous owner is no longer used.
        let restarted = try Self.bridge(store: store, calls: calls)
        let newToken = try await restarted.recordExplicitAnisetteConsent()
        let resumed = try await restarted.startRevalidation(consent: newToken)
        await resumed.waitUntilFinished()
        XCTAssertEqual(store.state.insertions, 1)
        XCTAssertEqual(store.state.journal?.selectedReference, reference)
        let snapshot = await restarted.snapshot()
        guard case .awaitingTeamSelection(let operation, _) = snapshot.phase else { return XCTFail("Hint cannot authorize a team") }
        XCTAssertEqual(operation, resumed.operation)
        let counts = await calls.counts()
        XCTAssertEqual(counts, [2, 1, 1, 2])
    }

    func testSDKOrganizationCategoryIsNotPromotedToVerifiedPaidMembership() async throws {
        let store = Store()
        let bridge = try Self.bridge(store: store, calls: Calls(), category: .organization)
        let token = try await bridge.recordExplicitAnisetteConsent()
        let handle = try await Self.start(bridge, token: token)
        await handle.waitUntilFinished()
        let snapshot = await bridge.snapshot()
        guard case .awaitingTeamSelection(_, let metadata) = snapshot.phase else { return XCTFail("Expected authorized team metadata") }
        XCTAssertEqual(metadata.teams.first?.membership, .developerProgramUnverified)
    }

    func testProviderFailureNeverReachesSDKOrStorage() async throws {
        let store = Store()
        let calls = Calls()
        let bridge = try Self.bridge(store: store, calls: calls, failProvider: true)
        var outcomes = await bridge.outcomes().makeAsyncIterator()
        let token = try await bridge.recordExplicitAnisetteConsent()
        let handle = try await Self.start(bridge, token: token)
        await handle.waitUntilFinished()
        let event = await outcomes.next()
        XCTAssertEqual(event, .failed(handle.operation, .providerFailed))
        let counts = await calls.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
        XCTAssertTrue(store.state.items.isEmpty)
    }
    private final class Lifetime: NativeAccountBackendLifetime {
        let released: OSAllocatedUnfairLock<Bool>
        let expectation: XCTestExpectation
        init(released: OSAllocatedUnfairLock<Bool>, expectation: XCTestExpectation) {
            self.released = released; self.expectation = expectation
        }
        deinit { released.withLock { $0 = true }; expectation.fulfill() }
    }

    func testOwnerLifetimeSurvivesShutdownWhileProviderIgnoresCancellation() async throws {
        let store = Store()
        let calls = Calls()
        let gate = Gate()
        let released = OSAllocatedUnfairLock(initialState: false)
        let retired = expectation(description: "Bridge lifetime released after worker retirement")
        var bridge: Bridge? = try Self.bridge(store: store, calls: calls, providerGate: gate,
            lifetime: Lifetime(released: released, expectation: retired))
        let token = try await bridge!.recordExplicitAnisetteConsent()
        var handle: Bridge.Handle? = try await Self.start(bridge!, token: token)
        await gate.waitForEntry()
        await bridge!.shutdown()
        bridge = nil // analogous to dropping the public facade
        XCTAssertFalse(released.withLock { $0 })
        await gate.release()
        await handle?.waitUntilFinished()
        handle = nil
        await fulfillment(of: [retired], timeout: 2)
        let counts = await calls.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
        XCTAssertTrue(store.state.items.isEmpty)
    }

    func testShutdownPreservesAcceptedAccountAndTerminatesObservation() async throws {
        let store = Store()
        let bridge = try Self.bridge(store: store, calls: Calls())
        let token = try await bridge.recordExplicitAnisetteConsent()
        let handle = try await Self.start(bridge, token: token)
        await handle.waitUntilFinished()
        let saved = store.state.journal?.selectedReference
        XCTAssertNotNil(saved)
        var events = await bridge.outcomes().makeAsyncIterator()
        await bridge.shutdown()
        let end = await events.next()
        XCTAssertNil(end)
        XCTAssertEqual(store.state.journal?.selectedReference, saved)
        XCTAssertEqual(store.state.items.count, 1)
        do { _ = try await bridge.recordExplicitAnisetteConsent(); XCTFail("Closed") }
        catch { XCTAssertEqual(error as? Bridge.Failure, .closed) }
        do { _ = try await Self.start(bridge, token: token); XCTFail("Closed") }
        catch { XCTAssertEqual(error as? Bridge.Failure, .closed) }
    }

}
