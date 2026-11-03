import XCTest
import Vapor
import NIOSSL
@testable import ServerDependencyCompatibility

final class ServerApplicationFactoryTests: XCTestCase {
    // Configuration-only: never starts a listener or performs a TLS handshake.
    func testInstallerHTTPPolicy() {
        let app = ServerDependencyProbe.makeHTTPApplication(port: 9123)
        defer { app.shutdown() }
        XCTAssertNil(app.http.server.configuration.tlsConfiguration)
        XCTAssertEqual(app.http.server.configuration.port, 9123)
        XCTAssertTrue(app.http.server.configuration.tcpNoDelay)
        XCTAssertEqual(app.routes.defaultMaxBodySize.value, 128 * 1024 * 1024)
        XCTAssertFalse(app.routes.caseInsensitive)
    }

    func testHTTPSConfigurationIsNotDiscarded() {
        // Intentionally not a usable identity. Do not start this server. Real
        // identity generation/loading and handshake tests remain device gates.
        var tls = TLSConfiguration.makeServerConfiguration(certificateChain: [], privateKey: .file("/nonexistent/synthetic-test-key.pem"))
        tls.minimumTLSVersion = .tlsv12
        let app = ServerApplicationFactory.make(environment: .testing, threads: 1,
            hostname: "local.example.invalid", bindHost: "127.0.0.1", port: 9124,
            transport: .https(tls), bodyLimit: "128mb", caseInsensitive: false)
        defer { app.shutdown() }
        XCTAssertNotNil(app.http.server.configuration.tlsConfiguration)
        XCTAssertEqual(app.http.server.configuration.tlsConfiguration?.minimumTLSVersion, .tlsv12)
        XCTAssertEqual(app.http.server.configuration.port, 9124)
    }

    func testWebManagerKeepsDistinctBodyAndRoutingPolicy() {
        let app = ServerApplicationFactory.make(environment: .testing, threads: 2,
            hostname: "127.0.0.1", bindHost: "127.0.0.1", port: 9125,
            transport: .http, bodyLimit: "32mb", caseInsensitive: true)
        defer { app.shutdown() }
        XCTAssertEqual(app.routes.defaultMaxBodySize.value, 32 * 1024 * 1024)
        XCTAssertTrue(app.routes.caseInsensitive)
    }

    func testCryptoSharesTheCompatibilityTarget() {
        XCTAssertEqual(ServerDependencyProbe.digest([]), [
            0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
            0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
            0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
            0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55
        ])
    }
}
