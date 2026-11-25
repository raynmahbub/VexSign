import XCTest
@testable import VexSign

@MainActor
final class IdentityInstallationSeparationTests: XCTestCase {
    private func suiteDefaults() throws -> (UserDefaults, String) {
        let name = "IdentityInstallationSeparationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    func testSelectingAppleAccountDoesNotWriteAnyDeliveryKey() throws {
        let (defaults, name) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = SigningModeManager(defaults: defaults)
        defaults.set(0, forKey: "VexSign.installationMethod")
        defaults.set(0, forKey: SigningModeManager.preferredDirectMethodKey)

        manager.selectIdentity(.appleAccount)

        XCTAssertEqual(manager.identityChoice, .appleAccount)
        XCTAssertNil(defaults.string(forKey: SigningModeManager.methodKey))
        XCTAssertNil(defaults.string(forKey: SigningModeManager.preferenceKey))
        XCTAssertEqual(defaults.integer(forKey: "VexSign.installationMethod"), 0)
        XCTAssertTrue(InstallationMethodPolicy.changingIdentityPreservesDelivery(source: .appleAccount))
    }

    func testSelectingImportedCertificateDoesNotWriteAnyDeliveryKey() throws {
        let (defaults, name) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = SigningModeManager(defaults: defaults)
        manager.selectIdentity(.appleAccount)
        defaults.removeObject(forKey: SigningModeManager.preferenceKey)
        defaults.removeObject(forKey: SigningModeManager.methodKey)

        manager.selectIdentity(.importedCertificate)

        XCTAssertEqual(manager.identityChoice, .importedCertificate)
        XCTAssertNil(defaults.string(forKey: SigningModeManager.methodKey))
        XCTAssertNil(defaults.string(forKey: SigningModeManager.preferenceKey))
    }

    func testExplicitContainerSurvivesAnIdentityChange() throws {
        let (defaults, name) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = SigningModeManager(defaults: defaults)

        manager.selectMethod(.embeddedContainer)
        XCTAssertEqual(manager.methodChoice, .embeddedContainer)
        XCTAssertEqual(defaults.integer(forKey: "VexSign.installationMethod"), 2)

        manager.selectIdentity(.appleAccount)

        XCTAssertEqual(manager.identityChoice, .appleAccount)
        XCTAssertEqual(manager.methodChoice, .embeddedContainer)
        XCTAssertEqual(defaults.integer(forKey: "VexSign.installationMethod"), 2)
    }

    func testSelectingMethodNeverWritesTheIdentityKey() throws {
        let (defaults, name) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = SigningModeManager(defaults: defaults)
        manager.selectIdentity(.appleAccount)

        manager.selectMethod(.direct)
        manager.selectDirectMethod(1)
        manager.selectMethod(.embeddedContainer)

        XCTAssertEqual(defaults.string(forKey: SigningModeManager.identityKey), "appleAccount")
        XCTAssertEqual(manager.identityChoice, .appleAccount)
    }

    func testLegacyContainerSelectionRestoresTheSeparateMethodChoice() throws {
        let (defaults, name) = try suiteDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2, forKey: "VexSign.installationMethod")

        let manager = SigningModeManager(defaults: defaults)

        XCTAssertEqual(manager.methodChoice, .embeddedContainer)
        XCTAssertEqual(manager.identityChoice, .importedCertificate)
    }

    func testUnavailableContainerFailsClosedWithoutFallingBackToDirect() {
        let readiness = InstallationMethodReadiness(directAvailable: true, containerAvailable: false)
        let result = InstallationMethodPolicy.resolve(choice: .embeddedContainer, readiness: readiness)
        XCTAssertEqual(result.choice, .embeddedContainer)
        XCTAssertFalse(result.isUsable)
        XCTAssertTrue(InstallationMethodPolicy.resolve(choice: .direct, readiness: readiness).isUsable)
    }
}
