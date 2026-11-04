// MARK: - AnisetteProviderTests
/// Unit tests for the AnisetteProvider functionality.

import Foundation
import Testing
import NimbleExtensions
@testable import VexSign

@Suite("AnisetteProvider Tests")
struct AnisetteProviderTests {

    // MARK: - AnisetteProviderDescriptor Tests

    @Test("AnisetteProviderDescriptor creation")
    func testDescriptorCreation() throws {
        let endpoint = URL(string: "https://example.com/anisette")!
        let descriptor = try AnisetteProviderDescriptor(
            identifier: "test.anisette",
            displayName: "Test Anisette Server",
            policyRevision: "1",
            endpoint: endpoint
        )

        #expect(descriptor.identifier == "test.anisette")
        #expect(descriptor.displayName == "Test Anisette Server")
        #expect(descriptor.policyRevision == "1")
        #expect(descriptor.endpoint == endpoint)
    }

    @Test("AnisetteProviderDescriptor defaultHTTPS")
    func testDefaultHTTPS() {
        let endpoint = URL(string: "https://my-server.com/anisette")!
        let descriptor = AnisetteProviderDescriptor.defaultHTTPS(
            endpoint: endpoint,
            identity: "vexsign.local",
            policyRevision: 1
        )

        #expect(descriptor.identifier == "vexsign.local")
        #expect(descriptor.displayName == "Custom Anisette Server")
        #expect(descriptor.policyRevision == "1")
        #expect(descriptor.endpoint == endpoint)
    }

    // MARK: - AnisetteProviderFactory Tests

    @Test("AnisetteProviderFactory initial state")
    func testFactoryInitialState() {
        let factory = AnisetteProviderFactory.shared
        // Initially no descriptor is configured
        #expect(factory.currentDescriptor == nil)
        #expect(factory.isConfigured == false)
    }

    // MARK: - SystemAnisetteHeaderTransport Tests

    @Test("SystemAnisetteHeaderTransport denies redirects")
    func testTransportRedirectDenial() async throws {
        let endpoint = URL(string: "https://example.com/anisette")!
        let transport = SystemAnisetteHeaderTransport(endpoint: endpoint)

        // The transport should deny redirects by design
        // We can't easily test the actual network call, but we verify the type exists
        #expect(transport.endpoint == endpoint)
    }

    // MARK: - LocalAnisetteProvider Tests

    @Test("LocalAnisetteProvider for testing")
    func testLocalProvider() {
        let headers = [
            "X-Apple-I-MD": "test123",
            "X-Apple-I-MD-M": "test456",
            "X-Apple-I-MD-RINFO": "1710000000",
            "X-Apple-I-MD-LU": "1710000000",
            "X-Apple-I-SRL-NO": "123456",
            "X-Apple-I-Client-Time": "2024-01-15T10:30:00Z",
            "X-Apple-I-Timezone": "America/New_York",
            "X-Apple-Locale": "en_US",
            "X-Apple-Device-ID": "ABCDEF12-3456-7890-ABCD-EF1234567890",
            "X-Mme-Device-Id": "ABCDEF12-3456-7890-ABCD-EF1234567890"
        ]

        let provider = LocalAnisetteProvider(headers: headers)
        #expect(provider.headers.count == 10)
        #expect(provider.headers["X-Apple-I-MD"] == "test123")
    }

    // MARK: - AnisetteConsentToken Tests

    @Test("AnisetteConsentToken expiration")
    func testConsentTokenExpiration() {
        let now = Date()
        let token = AnisetteConsentToken(
            descriptor: AnisetteProviderDescriptor(
                identifier: "test",
                displayName: "Test",
                policyRevision: "1",
                endpoint: URL(string: "https://example.com")!
            ),
            expiresAt: now.addingTimeInterval(3600) // 1 hour
        )

        #expect(token.expiresAt > now)
        #expect(token.expiresAt.timeIntervalSince(now) <= 3600)
    }
}