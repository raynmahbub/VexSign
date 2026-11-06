import Foundation
import XCTest
import SideSign
@testable import NativeSigningLinkSmoke

final class SideSignAccountAdapterTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private actor Calls {
        var auth = 0
        var account = 0
        var teams = 0
        func authentication() { auth += 1 }
        func fetchAccount() { account += 1 }
        func fetchTeams() { teams += 1 }
        func counts() -> [Int] { [auth, account, teams] }
    }
    private enum Mode: Sendable { case success, credentials, repair, rawError, twoFactor, cancelAfterLogin }
    private struct Portal: SideSignAccountPortal {
        let mode: Mode
        let result: AuthSession
        let values: [Team]
        let accountResult: Account
        let calls: Calls
        func authenticate(appleID: String, password: String, anisetteData: AnisetteData,
                          xcodeVersion: String, machinePassword: String?,
                          accountRepairHandler: DeveloperPortal.AccountRepairHandler,
                          verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> AuthSession {
            await calls.authentication()
            switch mode {
            case .credentials: throw DeveloperPortalError.incorrectCredentials(cause: "RAW-SECRET")
            case .rawError: throw NSError(domain: "RAW-SECRET", code: 1, userInfo: [NSLocalizedDescriptionKey: "RAW-TOKEN"])
            case .repair:
                let url = URL(fileURLWithPath: "/never-opened")
                let choice = try await accountRepairHandler(url, "RAW-SECRET")
                guard case .cancel = choice else { throw DeveloperPortalError.unknown(cause: "Unsafe repair consent") }
                throw DeveloperPortalError.accountRepairRequired(url: url, message: "RAW-SECRET")
            case .twoFactor:
                guard let handler = verificationHandler else { throw DeveloperPortalError.requiresTwoFactorAuthentication }
                let delivery = try await handler(.selectDeliveryMethod(preferredMode: .trustedDevice, phoneNumbers: []))
                guard case .requestTrustedDevice = delivery else { throw DeveloperPortalError.invalid2FAResponse() }
                let response = try await handler(.trustedDevice(error: nil))
                guard case .verificationCode(let code) = response, code == "123456" else {
                    throw DeveloperPortalError.invalid2FAResponse()
                }
            case .cancelAfterLogin: withUnsafeCurrentTask { $0?.cancel() }
            case .success: break
            }
            return result
        }
        func fetchAccount(session: Session) async throws -> Account {
            await calls.fetchAccount()
            return accountResult
        }
        func fetchTeams(for account: Account, session: Session) async throws -> [Team] {
            await calls.fetchTeams()
            return values
        }
    }

    private static func headers(_ marker: String = "fresh") -> AnisetteData {
        AnisetteData(machineID: marker, oneTimePassword: "synthetic-otp", localUserID: "local",
                     routingInfo: "route", deviceID: "device", serialNumber: "serial", clientInfo: "client",
                     userAgent: "agent", clientTime: "time", locale: "en_US", timeZone: "UTC")
    }
    private static func session() -> AuthSession {
        AuthSession(account: Account(appleID: "fixture@example.invalid", identifier: "123"),
                    session: Session(dsid: "123", authToken: "SYNTHETIC-TOKEN", anisetteData: headers("old"),
                                     xcodeVersion: "26.2", creationDate: now.addingTimeInterval(-10),
                                     expirationDate: now.addingTimeInterval(60)))
    }
    private static func portal(_ mode: Mode = .success, teams: [Team]? = nil, account: Account? = nil) -> Portal {
        Portal(mode: mode, result: session(), values: teams ?? [Team(identifier: "FREE", name: "Fixture", type: .free)],
               accountResult: account ?? session().account, calls: Calls())
    }
    private static func authenticate(_ portal: Portal) async throws -> SideSignPreparedAccountSession {
        let adapter = SideSignAccountAdapter(portal: portal, clock: { Self.now })
        return try await adapter.authenticate(appleID: "fixture@example.invalid", password: "SYNTHETIC-PASSWORD",
                                              freshAnisetteData: headers(), xcodeVersion: "26.2",
                                              twoFactor: SideSignTwoFactorBroker(operation: UUID()))
    }

    func testAuthenticationEnumeratesTeamsAndReturnsOnlyPreparedSession() async throws {
        let portal = Self.portal()
        let prepared = try await Self.authenticate(portal)
        XCTAssertEqual(prepared.teams.map(\.identifier), ["FREE"])
        XCTAssertEqual(prepared.teams.first?.category, .free)
        XCTAssertEqual(prepared.expiresAt, Self.now.addingTimeInterval(60))
        let decoded = try SideSignSessionCodec.decodeForRevalidation(prepared.encodedSession,
                                                                     freshAnisetteData: Self.headers(), now: Self.now)
        XCTAssertEqual(decoded.session.authToken, "SYNTHETIC-TOKEN")
        let counts = await portal.calls.counts()
        XCTAssertEqual(counts, [1, 0, 1])
    }

    func testCredentialRepairAndRawErrorsAreSanitized() async throws {
        let cases: [(Mode, SideSignAccountAdapterError)] = [
            (.credentials, .incorrectCredentials), (.repair, .accountRepairRequired), (.rawError, .requestFailed)
        ]
        for (mode, expected) in cases {
            do {
                _ = try await Self.authenticate(Self.portal(mode))
                XCTFail("Expected sanitized failure")
            } catch {
                XCTAssertEqual(error as? SideSignAccountAdapterError, expected)
                XCTAssertFalse(String(describing: error).contains("RAW-"))
            }
        }
    }

    func testUnknownDuplicateAndEmptyTeamsFailClosed() async throws {
        let variants: [[Team]] = [
            [], [Team(identifier: "UNKNOWN", name: "Fixture", type: .unknown)],
            [Team(identifier: "SAME", name: "One", type: .free), Team(identifier: "SAME", name: "Two", type: .free)]
        ]
        for values in variants {
            do { _ = try await Self.authenticate(Self.portal(teams: values)); XCTFail("Reject invalid teams") }
            catch { XCTAssertNotNil(error as? SideSignAccountAdapterError) }
        }
    }

    func testCancellationAfterLoginPreventsTeamFetchAndPersistenceOutput() async throws {
        let portal = Self.portal(.cancelAfterLogin)
        let task = Task.detached { [portal] in
            try await SideSignAccountAdapterTests.authenticate(portal)
        }
        do { _ = try await task.value; XCTFail("Cancellation must not publish session bytes") }
        catch { XCTAssertTrue(error is CancellationError) }
        let counts = await portal.calls.counts()
        XCTAssertEqual(counts, [1, 0, 0])
    }

    func testInvalidHeadersDoNotReachPortal() async throws {
        let portal = Self.portal()
        let adapter = SideSignAccountAdapter(portal: portal, clock: { Self.now })
        var headers = Self.headers()
        headers.oneTimePassword = ""
        do {
            _ = try await adapter.authenticate(appleID: "fixture@example.invalid", password: "synthetic",
                                               freshAnisetteData: headers, xcodeVersion: "26.2",
                                               twoFactor: SideSignTwoFactorBroker(operation: UUID()))
            XCTFail("Invalid headers must fail before credentials reach the portal")
        } catch { XCTAssertEqual(error as? SideSignSessionCodecError, .invalidFields) }
        let counts = await portal.calls.counts()
        XCTAssertEqual(counts, [0, 0, 0])
    }

    func testRevalidationFetchesAccountAndTeamsUsingExistingToken() async throws {
        let portal = Self.portal()
        let adapter = SideSignAccountAdapter(portal: portal, clock: { Self.now })
        let encoded = try SideSignSessionCodec.encode(Self.session(), now: Self.now)
        let prepared = try await adapter.revalidate(encodedSession: encoded, freshAnisetteData: Self.headers())
        XCTAssertEqual(prepared.teams.first?.identifier, "FREE")
        let counts = await portal.calls.counts()
        XCTAssertEqual(counts, [0, 1, 1])
    }

    func testRevalidationAccountMismatchNeverEnumeratesTeams() async throws {
        let portal = Self.portal(account: Account(appleID: "other@example.invalid", identifier: "other"))
        let adapter = SideSignAccountAdapter(portal: portal, clock: { Self.now })
        let encoded = try SideSignSessionCodec.encode(Self.session(), now: Self.now)
        do {
            _ = try await adapter.revalidate(encodedSession: encoded, freshAnisetteData: Self.headers())
            XCTFail("Token account must match the saved account")
        } catch { XCTAssertEqual(error as? SideSignAccountAdapterError, .invalidPortalResponse) }
        let counts = await portal.calls.counts()
        XCTAssertEqual(counts, [0, 1, 0])
    }

    func testAdapterUsesOperationBoundTwoFactorBroker() async throws {
        let portal = Self.portal(.twoFactor)
        let adapter = SideSignAccountAdapter(portal: portal, clock: { Self.now })
        let operation = UUID()
        let broker = SideSignTwoFactorBroker(operation: operation)
        var events = await broker.challengeEvents().makeAsyncIterator()
        let task = Task.detached { [adapter, broker] in
            try await adapter.authenticate(appleID: "fixture@example.invalid", password: "synthetic",
                                           freshAnisetteData: SideSignAccountAdapterTests.headers(), xcodeVersion: "26.2", twoFactor: broker)
        }
        defer { task.cancel() }
        let firstEvent = await events.next()
        let first = try XCTUnwrap(firstEvent)
        let delivered = await broker.submit(.requestTrustedDevice, operation: operation, challengeID: first.id)
        XCTAssertTrue(delivered)
        let secondEvent = await events.next()
        let second = try XCTUnwrap(secondEvent)
        XCTAssertNotEqual(first.id, second.id)
        let submitted = await broker.submit(.verificationCode("123456"), operation: operation, challengeID: second.id)
        XCTAssertTrue(submitted)
        let prepared = try await task.value
        XCTAssertEqual(prepared.teams.first?.identifier, "FREE")
        let pending = await broker.pendingChallenge()
        XCTAssertNil(pending)
    }
}
