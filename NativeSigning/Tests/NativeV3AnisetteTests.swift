import Foundation
import XCTest
import SideSign
import os
@testable import NativeSigningLinkSmoke

final class NativeV3AnisetteTests: XCTestCase {
    private struct Store: NativeV3AnisetteStateStorage {
        let state = OSAllocatedUnfairLock<NativeV3AnisetteState?>(initialState: nil)
        func load() -> NativeV3AnisetteState? { state.withLock { $0 } }
        func save(_ value: NativeV3AnisetteState) throws {
            try value.validate()
            state.withLock { $0 = value }
        }
    }
    private actor Transport: NativeV3AnisetteTransport {
        var identifiers: [UUID] = []
        var blobs: [Data?] = []
        let fail: Bool
        init(fail: Bool = false) { self.fail = fail }
        func headers(identifier: UUID, blob: Data?) throws -> (data: AnisetteData, blob: Data?) {
            identifiers.append(identifier); blobs.append(blob)
            if fail { throw URLError(.cannotConnectToHost) }
            return (NativeV3AnisetteTests.headers(identifier), blob == nil ? Data([1, 2, 3]) : nil)
        }
        func calls() -> ([UUID], [Data?]) { (identifiers, blobs) }
    }
    private static func headers(_ identifier: UUID) -> AnisetteData {
        .init(machineID: Data([1]).base64EncodedString(), oneTimePassword: Data([2]).base64EncodedString(),
              localUserID: "fixture", routingInfo: "17106176", deviceID: identifier.uuidString,
              serialNumber: "0", clientInfo: "fixture", userAgent: "fixture",
              clientTime: ISO8601DateFormatter().string(from: Date()), locale: "en_US", timeZone: "UTC")
    }
    private func descriptor(_ kind: AnisetteProviderDescriptor.ProtocolKind = .v3) throws -> AnisetteProviderDescriptor {
        try .init(identifier: "fixture", displayName: "Fixture", policyRevision: "1",
                  endpoint: URL(string: "https://provider.example.invalid"), protocolKind: kind)
    }
    func testIdentifierAndBlobAreReusedAcrossProviderInstances() async throws {
        let store = Store(), transport = Transport()
        let first = try NativeV3AnisetteProvider(descriptor: descriptor(), transport: transport, storage: store)
        _ = try await first.freshHeaders()
        let second = try NativeV3AnisetteProvider(descriptor: descriptor(), transport: transport, storage: store)
        _ = try await second.freshHeaders()
        let calls = await transport.calls()
        XCTAssertEqual(calls.0.count, 2)
        XCTAssertEqual(calls.0.first, calls.0.last)
        XCTAssertNil(calls.1[0])
        XCTAssertEqual(calls.1[1], Data([1, 2, 3]))
    }
    func testTransportFailureDoesNotRotateIdentifier() async throws {
        let store = Store(), transport = Transport(fail: true)
        let provider = try NativeV3AnisetteProvider(descriptor: descriptor(), transport: transport, storage: store)
        for _ in 0..<2 {
            do { _ = try await provider.freshHeaders(); XCTFail("Expected transport failure") }
            catch { XCTAssertNotNil(store.load()) }
        }
        let calls = await transport.calls()
        XCTAssertEqual(calls.0.first, calls.0.last)
        XCTAssertNil(store.load()?.adiBlob)
    }
    func testProtocolIsPartOfConsentIdentity() throws {
        XCTAssertNotEqual(try descriptor(.headers), try descriptor(.v3))
        XCTAssertThrowsError(try NativeV3AnisetteProvider(descriptor: descriptor(.headers), transport: Transport(), storage: Store()))
    }
    func testHeaderBindingAndControlCharactersAreRejected() throws {
        let id = UUID()
        var value = Self.headers(id)
        XCTAssertNoThrow(try NativeV3AnisetteProvider.validate(value, identifier: id, now: Date()))
        XCTAssertThrowsError(try NativeV3AnisetteProvider.validate(value, identifier: UUID(), now: Date()))
        value.userAgent = "injected\r\nHeader: value"
        XCTAssertThrowsError(try NativeV3AnisetteProvider.validate(value, identifier: id, now: Date()))
    }
    func testOversizedBlobIsRejected() {
        XCTAssertThrowsError(try NativeV3AnisetteState(identifier: UUID(), adiBlob: Data(repeating: 1, count: 65_537)).validate())
    }
}
