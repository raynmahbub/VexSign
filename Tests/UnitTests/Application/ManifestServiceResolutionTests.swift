import XCTest
@testable import VexSign

/// An unverified manifest endpoint must never become an `itms-services` link.
/// These tests exercise the network-free selection rule; the live probes remain
/// in `ManifestService._serves`.
final class ManifestServiceResolutionTests: XCTestCase {
    private func candidates() throws -> [URL] {
        try [
            XCTUnwrap(URL(string: "https://manifest-one.example/genPlist")),
            XCTUnwrap(URL(string: "https://manifest-two.example/genPlist")),
            XCTUnwrap(URL(string: "https://manifest-three.example/genPlist")),
        ]
    }

    func testNoServingEndpointProducesNoInstallManifest() async throws {
        let urls = try candidates()
        var probed: [URL] = []
        let resolved = await ManifestService.select(candidates: urls) { url in
            probed.append(url)
            return false
        }
        XCTAssertNil(resolved)
        XCTAssertEqual(probed, urls, "every candidate must be checked before refusing")
    }

    func testFirstPositivelyVerifiedEndpointWins() async throws {
        let urls = try candidates()
        var probed: [URL] = []
        let resolved = await ManifestService.select(candidates: urls) { url in
            probed.append(url)
            return url == urls[1]
        }
        XCTAssertEqual(resolved, urls[1])
        XCTAssertEqual(probed, Array(urls.prefix(2)), "later endpoints must not be probed after success")
    }

    func testEmptyCandidateListDoesNotProbe() async {
        var probeCount = 0
        let resolved = await ManifestService.select(candidates: []) { _ in
            probeCount += 1
            return true
        }
        XCTAssertNil(resolved)
        XCTAssertEqual(probeCount, 0)
    }

    /// Semi Local sends the LAN payload URL — including the per-install token — to
    /// these hosts, and the UI names them before the first attempt. If the list
    /// changes, the disclosure has to change with it.
    func testDisclosedManifestHostsAreTheOnesUsed() {
        XCTAssertEqual(
            ManifestService.manifestHosts,
            ["vexsign-install.vexsign.workers.dev", "api.palera.in"]
        )
        XCTAssertEqual(Set(ManifestService.manifestHosts).count, ManifestService.manifestHosts.count)
    }
}
