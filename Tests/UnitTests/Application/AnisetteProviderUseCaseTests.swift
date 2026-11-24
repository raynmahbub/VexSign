import Foundation
import XCTest
@testable import VexSign

@MainActor
final class AnisetteProviderUseCaseTests: XCTestCase {
    private enum ProbeFailure: Error { case unavailable }

    private final class Provider: AnisetteConfigurationProviding {
        var currentConfiguration: AnisetteConfiguration?
        var calls: [String] = []
        var probeError: Error?
        let catalog = AnisetteServerCatalog(
            servers: [.init(name: "Reference", address: "https://example.com/", kind: 1)],
            sourceRepository: "test/reference", sourceRevision: "test", reviewedAt: "2026-11-13"
        )

        func loadBundledCatalog() throws -> AnisetteServerCatalog { catalog }
        func probe(_ configuration: AnisetteConfiguration) async throws {
            calls.append("probe")
            if let probeError { throw probeError }
        }
        func save(_ configuration: AnisetteConfiguration) throws {
            calls.append("save")
            currentConfiguration = configuration
        }
        func clear() { calls.append("clear"); currentConfiguration = nil }
        func synchronize() async { calls.append("synchronize") }
    }

    func testEndpointPolicyRejectsCredentialsQueryFragmentAndPlainHTTP() throws {
        let useCase = AnisetteProviderUseCase(provider: Provider())
        for endpoint in ["", "http://example.com", "https://user:password@example.com",
                         "https://example.com/path?token=value", "https://example.com/#fragment"] {
            XCTAssertThrowsError(try useCase.validateEndpoint(endpoint), endpoint)
        }
        XCTAssertEqual(try useCase.validateEndpoint("  https://example.com/v3 \n").absoluteString,
                       "https://example.com/v3")
    }

    func testVerifiedConfigurationUsesThePortInOrder() async throws {
        let provider = Provider()
        let useCase = AnisetteProviderUseCase(provider: provider)

        try await useCase.saveConfiguration(
            endpoint: "https://example.com/v3", identity: "chosen-provider", displayName: "Chosen",
            policyRevision: "2", protocolKind: .v3, verifyBeforeSaving: true
        )

        XCTAssertEqual(provider.calls, ["probe", "save", "synchronize"])
        XCTAssertEqual(useCase.currentConfiguration?.identifier, "chosen-provider")
        XCTAssertEqual(useCase.currentConfiguration?.protocolKind, .v3)
    }

    func testFailedProbeCannotPersistOrSynchronizeConfiguration() async {
        let provider = Provider()
        provider.probeError = ProbeFailure.unavailable
        let useCase = AnisetteProviderUseCase(provider: provider)
        do {
            try await useCase.saveConfiguration(
                endpoint: "https://example.com/", identity: "provider", displayName: "Chosen",
                policyRevision: "1", protocolKind: .headers, verifyBeforeSaving: true
            )
            XCTFail("Expected probe failure")
        } catch ProbeFailure.unavailable {
            // The rejected candidate must not change the active provider.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(provider.calls, ["probe"])
        XCTAssertNil(provider.currentConfiguration)
    }

    func testCancelledProbeCannotActivateConfigurationAfterTheEditorCloses() async {
        let provider = Provider()
        let useCase = AnisetteProviderUseCase(provider: provider)
        await withTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask { @MainActor in
                do {
                    try await useCase.saveConfiguration(
                        endpoint: "https://example.com/", identity: "provider", displayName: "Chosen",
                        policyRevision: "1", protocolKind: .headers, verifyBeforeSaving: true
                    )
                    XCTFail("Cancelled save must not activate a provider")
                } catch is CancellationError {
                    // Even a probe that ignores cancellation cannot save afterwards.
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
            await group.waitForAll()
        }
        XCTAssertEqual(provider.calls, ["probe"])
        XCTAssertNil(provider.currentConfiguration)
    }

    func testClearUsesTheExistingProviderAndSynchronizes() async throws {
        let provider = Provider()
        let useCase = AnisetteProviderUseCase(provider: provider)
        try await useCase.saveConfiguration(
            endpoint: "https://example.com/", identity: "provider", displayName: "Chosen",
            policyRevision: "1", protocolKind: .headers, verifyBeforeSaving: false
        )
        provider.calls = []

        await useCase.clearConfiguration()

        XCTAssertEqual(provider.calls, ["clear", "synchronize"])
        XCTAssertNil(useCase.currentConfiguration)
    }

    func testCatalogueLoadingIsInjectedRatherThanBundleIOInApplication() throws {
        let useCase = AnisetteProviderUseCase(provider: Provider())
        let catalog = try useCase.loadBundledCatalog()
        XCTAssertEqual(catalog.sourceRepository, "test/reference")
        XCTAssertEqual(catalog.servers.first?.secureEndpoint?.absoluteString, "https://example.com/")
    }
}
