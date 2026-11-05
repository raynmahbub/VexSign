// MARK: - AnisetteProviderTests
/// Unit tests for the AnisetteProvider functionality.
///
/// The descriptor, its consent errors and the HTTPS provider all live in `NativeSigning`;
/// the factory and the local provider are the app's. Both modules are named here, so the
/// import list is longer than a pure app-level test file.

import Foundation
import Testing
import NativeSigning
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

    @Test("AnisetteProviderDescriptor refuses a non-HTTPS endpoint")
    func testRejectsInsecureEndpoint() {
        var thrown: Error?
        do {
            _ = try AnisetteProviderDescriptor(
                identifier: "test.anisette",
                displayName: "Test Anisette Server",
                policyRevision: "1",
                endpoint: URL(string: "http://example.com/anisette")!
            )
        } catch {
            thrown = error
        }
        #expect(thrown as? AnisetteConsentError == .invalidProvider)
    }

    @Test("AnisetteProviderDescriptor refuses credentials in the endpoint")
    func testRejectsSecretBearingEndpoint() {
        var thrown: Error?
        do {
            _ = try AnisetteProviderDescriptor(
                identifier: "test.anisette",
                displayName: "Test Anisette Server",
                policyRevision: "1",
                endpoint: URL(string: "https://user:password@example.com/anisette")!
            )
        } catch {
            thrown = error
        }
        #expect(thrown as? AnisetteConsentError == .invalidProvider)
    }

    // MARK: - AnisetteProviderFactory Tests

    @MainActor
    @Test("AnisetteProviderFactory has no provider before configuration")
    func testFactoryInitialState() {
        let factory = AnisetteProviderFactory.shared
        factory.clearConfiguration()

        #expect(factory.currentDescriptor == nil)
        #expect(factory.isConfigured == false)
        #expect(factory.makeProvider() == nil)
    }

    @MainActor
    @Test("AnisetteProviderFactory configures and clears a custom HTTPS endpoint")
    func testFactoryConfigureAndClear() throws {
        let factory = AnisetteProviderFactory.shared
        defer { factory.clearConfiguration() }

        try factory.configureHTTPS(endpoint: URL(string: "https://my-server.com/anisette")!)

        #expect(factory.isConfigured == true)
        #expect(factory.currentDescriptor?.identifier == "vexsign.local")
        #expect(factory.currentDescriptor?.displayName == "Custom Anisette Server")
        #expect(factory.currentDescriptor?.policyRevision == "1")

        factory.clearConfiguration()

        #expect(factory.isConfigured == false)
        #expect(factory.currentDescriptor == nil)
    }

    @MainActor
    @Test("AnisetteProviderFactory builds the provider its descriptor describes")
    func testFactoryMakesProvider() throws {
        let factory = AnisetteProviderFactory.shared
        defer { factory.clearConfiguration() }

        try factory.configureHTTPS(endpoint: URL(string: "https://my-server.com/anisette")!)

        // Same construction the factory does internally; if the transport and the
        // provider's constrained initializer ever drift apart this stops compiling.
        let descriptor = AnisetteProviderDescriptor.defaultHTTPS(
            endpoint: URL(string: "https://my-server.com/anisette")!,
            identity: "vexsign.local",
            policyRevision: 1
        )
        let provider = try HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>(descriptor: descriptor)

        #expect(provider.descriptor == descriptor)
        #expect(factory.makeProvider() != nil)
    }

    // MARK: - LocalAnisetteProvider Tests

    @Test("LocalAnisetteProvider refuses to invent headers")
    func testLocalProviderWithoutStaticHeaders() async {
        let descriptor = AnisetteProviderDescriptor.defaultHTTPS(
            endpoint: URL(string: "https://my-server.com/anisette")!,
            identity: "vexsign.local",
            policyRevision: 1
        )
        let provider = LocalAnisetteProvider(descriptor: descriptor)
        #expect(provider.descriptor == descriptor)

        // No static headers and no endpoint of its own: it must fail rather than
        // hand back a plausible-looking anisette response.
        var thrown: Error?
        do {
            _ = try await provider.freshHeaders()
        } catch {
            thrown = error
        }
        #expect(thrown as? HTTPSAnisetteProviderError == .remoteEndpointRequired)
    }
}
