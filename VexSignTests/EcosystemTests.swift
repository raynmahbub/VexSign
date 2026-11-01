import XCTest
@testable import VexSign

final class EcosystemTests: XCTestCase {
    private func sample() -> RepositoryDocument {
        var app = RepositoryApp()
        app.name = "Example"; app.bundleIdentifier = "com.example.app"
        app.versionDate = "2026-09-19T00:00:00Z"
        app.downloadURL = "https://example.com/app.ipa?a=1&b=2"
        app.iconURL = "https://example.com/icon.png"; app.size = 1024
        return RepositoryDocument(name: "Examples", identifier: "com.example.source", apps: [app])
    }

    func testCommonFormatsRoundTrip() throws {
        for format in RepositoryFormat.allCases {
            let original = sample()
            let files = try RepositoryExporter.encode(original, as: format)
            let decoded = try RepositoryImporter.decode(files.source, format: format)
            XCTAssertEqual(decoded.name, original.name)
            XCTAssertEqual(decoded.apps.first?.bundleIdentifier, original.apps.first?.bundleIdentifier)
            XCTAssertEqual(decoded.apps.first?.downloadURL, original.apps.first?.downloadURL)
            let split = try RepositoryImporter.decode(files.source, format: format, appsData: files.apps)
            XCTAssertEqual(split.apps.count, 1)
        }
    }
    func testUnknownProviderMetadataSurvivesAltStoreRoundTrip() throws {
        var doc = sample()
        doc.extra["userInfo"] = .object(["key": .string("value")])
        doc.apps[0].extra["appPermissions"] = .object(["entitlements": .array([])])
        let decoded = try RepositoryImporter.decode(RepositoryExporter.encode(doc, as: .altStore).source)
        XCTAssertEqual(decoded.extra["userInfo"], doc.extra["userInfo"])
        XCTAssertEqual(decoded.apps[0].extra["appPermissions"], doc.apps[0].extra["appPermissions"])
    }
    func testMalformedAndOversizedInputsAreRejected() {
        XCTAssertThrowsError(try RepositoryImporter.decode(Data("{".utf8)))
        XCTAssertThrowsError(try RepositoryImporter.decode(Data("[]".utf8)))
        XCTAssertThrowsError(try RepositoryImporter.decode(Data(repeating: 0, count: RepositoryImporter.maximumBytes + 1)))
    }
    func testDuplicatesInvalidURLsAndSafeFixes() {
        var doc = sample()
        doc.apps.append(doc.apps[0])
        doc.apps[1].id = UUID()
        XCTAssertTrue(RepositoryValidator.validate(doc).contains { $0.message.contains("Duplicate bundle") })
        doc.apps.removeLast()
        doc.apps[0].downloadURL = " https://example.com/app.ipa "
        doc.apps[0].screenshotURLs = ["https://example.com/1.png", "https://example.com/1.png"]
        XCTAssertTrue(RepositoryValidator.validate(doc).contains { $0.fix != nil })
        RepositoryValidator.applySafeFixes(to: &doc)
        XCTAssertEqual(doc.apps[0].screenshotURLs.count, 1)
        XCTAssertFalse(RepositoryValidator.validate(doc).contains { $0.severity == .error })
        XCTAssertNil(RepositoryValidator.webURL("file:///private/key.p12"))
        XCTAssertNil(RepositoryValidator.webURL("https://user:password@example.com"))
        XCTAssertNil(RepositoryValidator.webURL("javascript:alert(1)"))
    }
    func testCloneIDsAvoidExistingIDsAndValidateBounds() throws {
        let plans = try ClonePlan.make(bundleID: "com.example.app", name: "Example", count: 2, existing: ["com.example.app.clone1"])
        XCTAssertEqual(plans.map(\.bundleIdentifier), ["com.example.app.clone2", "com.example.app.clone3"])
        XCTAssertThrowsError(try ClonePlan.make(bundleID: "../evil", name: "Example", count: 1, existing: []))
        XCTAssertThrowsError(try ClonePlan.make(bundleID: "com.example.app", name: "Example", count: 21, existing: []))
    }
    func testManifestSerializationAndInstallLinkEncoding() throws {
        let download = try XCTUnwrap(URL(string: "https://example.com/a.ipa?x=1&y=2"))
        let data = try OTAExporter.manifest(.init(name: "A & B", bundleIdentifier: "com.example.app", version: "1.0", downloadURL: download, iconURL: nil))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertNotNil(object?["items"])
        let url = try XCTUnwrap(URL(string: "https://example.com/manifest?token=a&x=b"))
        let link = try OTAExporter.installLink(manifestURL: url)
        XCTAssertEqual(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value, url.absoluteString)
        XCTAssertThrowsError(try OTAExporter.installLink(manifestURL: XCTUnwrap(URL(string: "http://example.com/a"))))
    }
    func testUnsignedOrUnknownIsNotGoodCertificateEvidence() {
        // The reader that parsed a third-party verdict is gone; only the
        // on-device OCSP result reaches the badge now, and a non-answer is Unknown.
        XCTAssertEqual(CertificateStatusValue(revocation: .unknown), .unknown)
        XCTAssertEqual(CertificateStatusValue(revocation: .revoked), .revoked)
        XCTAssertEqual(CertificateStatusValue(revocation: .good), .signed)
    }
    func testRankingUsesFavoritesWithoutFabricatedGlobalDownloads() {
        let app = DiscoveryApp(id: "a", source: "s", bundleIdentifier: "com.example.app", name: "Example", summary: "", developer: "", category: "", version: "1", icon: nil, download: nil, updated: Date(), releases: 1)
        let now = Date()
        var signals = DiscoverySignals()
        let original = DiscoveryRanking.score(app, signals: signals, now: now)
        signals.favorites.insert(app.id)
        XCTAssertEqual(DiscoveryRanking.score(app, signals: signals, now: now), original + 4, accuracy: 0.00001)
    }

    func testCanonicalAppGroupingAndMultiSourceVersions() async {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 1500)

        let app1 = DiscoveryApp(id: "s1#com.example.app", source: "https://repo1.com", bundleIdentifier: "com.example.app", name: "Example App", summary: "First", developer: "Dev", category: "Utilities", version: "1.0", icon: nil, download: nil, updated: date1, releases: 1)
        let app2 = DiscoveryApp(id: "s2#com.example.app", source: "https://repo2.com", bundleIdentifier: "com.example.app", name: "Example App", summary: "Second", developer: "Dev", category: "Utilities", version: "2.0", icon: nil, download: nil, updated: date2, releases: 2)
        let app3 = DiscoveryApp(id: "s3#com.example.app", source: "https://repo3.com", bundleIdentifier: "com.example.app", name: "Example App", summary: "Third", developer: "Dev", category: "Utilities", version: "1.5", icon: nil, download: nil, updated: date3, releases: 3)
        let otherApp = DiscoveryApp(id: "s1#com.other.app", source: "https://repo1.com", bundleIdentifier: "com.other.app", name: "Other App", summary: "Other", developer: "Dev", category: "Games", version: "1.0", icon: nil, download: nil, updated: date1, releases: 1)

        let index = DiscoveryIndex()
        await index.replace([app1, app2, app3, otherApp])

        let groups = await index.canonicalGroups()
        XCTAssertEqual(groups.count, 2)

        let exampleGroup = try? XCTUnwrap(groups.first { $0.bundleIdentifier == "com.example.app" })
        XCTAssertEqual(exampleGroup?.primaryApp.version, "2.0")
        XCTAssertEqual(exampleGroup?.versions.count, 3)
        XCTAssertEqual(exampleGroup?.sourceCount, 3)
        XCTAssertTrue(exampleGroup?.hasMultipleSources == true)

        let versions = await index.versions(for: "com.example.app")
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(versions[0].version, "2.0")
        XCTAssertEqual(versions[1].version, "1.5")
        XCTAssertEqual(versions[2].version, "1.0")
    }

    func testDiagnosticBundleSanitizerRedactsSecrets() {
        let sampleLog = """
        [INFO] Attempting sign with certificate password: "mySuperSecretPassword123"
        [INFO] Auth header: Bearer abcdef1234567890abcdef1234567890
        [INFO] Storing key:
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA0Y3
        -----END RSA PRIVATE KEY-----
        [INFO] Finished operation.
        """

        let sanitized = DiagnosticBundleExporter._sanitize(sampleLog)
        XCTAssertFalse(sanitized.contains("mySuperSecretPassword123"))
        XCTAssertTrue(sanitized.contains("[REDACTED]"))
        XCTAssertFalse(sanitized.contains("abcdef1234567890abcdef1234567890"))
        XCTAssertTrue(sanitized.contains("[REDACTED_TOKEN]"))
        XCTAssertFalse(sanitized.contains("MIIEowIBAAKCAQEA0Y3"))
        XCTAssertTrue(sanitized.contains("[REDACTED_PRIVATE_KEY_BLOCK]"))
    }

    func testLocalCAProfileGeneratesValidMobileconfig() throws {
        let dummyPEM = """
        -----BEGIN CERTIFICATE-----
        MIIBkzCCATigAwIBAgIUQ==
        -----END CERTIFICATE-----
        """

        let der = LocalCAProfile.extractRootCertificateDER(from: dummyPEM)
        XCTAssertNotNil(der)

        if let der {
            let configData = LocalCAProfile.buildMobileConfig(caCertificateDER: der, displayName: "Test Root CA")
            XCTAssertNotNil(configData)
            if let configData {
                let plist = try PropertyListSerialization.propertyList(from: configData, format: nil) as? [String: Any]
                XCTAssertEqual(plist?["PayloadType"] as? String, "Configuration")
                let payloadContent = plist?["PayloadContent"] as? [[String: Any]]
                XCTAssertEqual(payloadContent?.first?["PayloadType"] as? String, "com.apple.security.root")
            }
        }
    }

    func testCloudSigningRequestSerialization() throws {
        let req = CloudSignRequest(ipaId: "ipa-1", p12Id: "p12-1", provisionId: "prov-1", password: "pwd", webhook: "https://example.com/hook")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(CloudSignRequest.self, from: data)
        XCTAssertEqual(decoded.ipaId, "ipa-1")
        XCTAssertEqual(decoded.password, "pwd")
        XCTAssertEqual(decoded.webhook, "https://example.com/hook")
    }
}

// MARK: - Community catalogue disclosure
/// The community catalogue (NexCerts) hands VexSign a shared Apple identity from a third-party
/// host. These tests pin the two things the UI promises: the disclosure is bound to the host that
/// actually serves the files, and "turn this source off" really forgets it.
final class NexCertsSourceTests: XCTestCase {
	private func _temporaryDefaults() -> UserDefaults {
		let name = "test.nexcerts.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: name)!
		addTeardownBlock { defaults.removePersistentDomain(forName: name) }
		return defaults
	}

	func testNothingIsAcknowledgedOnAFreshInstall() {
		XCTAssertFalse(NexCertsAccess.hasAcknowledged(_temporaryDefaults()))
	}

	func testEveryDownloadStaysOnTheDisclosedHost() {
		// If the catalogue ever moves, the disclosure copy is wrong until someone notices.
		XCTAssertEqual(NexCerts.sourceHost, "sideloading.net")

		let urls = NexCerts.downloadURLs(for: 7)

		for url in [urls.p12, urls.provision, urls.password] {
			XCTAssertEqual(url.host, NexCerts.sourceHost, "\(url) left the disclosed host")
			XCTAssertEqual(url.scheme, "https", "\(url) is not encrypted in transit")
			XCTAssertTrue(url.path.contains("/download/7/"), "unexpected path \(url.path)")
		}
	}

	func testAcknowledgementIsRemembered() {
		let defaults = _temporaryDefaults()

		NexCertsAccess.acknowledge(defaults)

		XCTAssertTrue(NexCertsAccess.hasAcknowledged(defaults))
		XCTAssertEqual(defaults.string(forKey: NexCertsAccess.acknowledgementKey), NexCerts.sourceHost)
	}

	func testAcknowledgementDoesNotCarryOverToADifferentHost() {
		let defaults = _temporaryDefaults()
		defaults.set("example.invalid", forKey: NexCertsAccess.acknowledgementKey)

		XCTAssertFalse(
			NexCertsAccess.hasAcknowledged(defaults),
			"an acknowledgement given for another host must not cover this one"
		)
	}

	func testRevokingTheSourceForgetsTheAcknowledgement() {
		let defaults = _temporaryDefaults()
		NexCertsAccess.acknowledge(defaults)

		NexCertsAccess.revoke(defaults)

		XCTAssertFalse(NexCertsAccess.hasAcknowledged(defaults))
		XCTAssertNil(defaults.string(forKey: NexCertsAccess.acknowledgementKey))
	}
}
