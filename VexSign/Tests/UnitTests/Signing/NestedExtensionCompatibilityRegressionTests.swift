import XCTest
@testable import VexSign

final class NestedExtensionCompatibilityRegressionTests: XCTestCase {
    private func makeTempRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func writeComponent(
        at url: URL,
        identifier: String,
        executableName: String,
        packageType: String,
        extensionPoint: String? = nil,
        fileType: UInt32 = 2,
        platform: UInt32 = 2,
        entitlements: [String: Any] = [:]
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": packageType,
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0"
        ]
        if let extensionPoint {
            info["NSExtension"] = ["NSExtensionPointIdentifier": extensionPoint]
        }
        try SigningRegressionFixture.plist(info).write(to: url.appendingPathComponent("Info.plist"))
        try SigningRegressionFixture.machO(entitlements: entitlements, fileType: fileType, platform: platform)
            .write(to: url.appendingPathComponent(executableName))
    }

    private func buildFullNestedCorpus(in root: URL) throws -> URL {
        let appURL = root.appendingPathComponent("VexCorpus.app", isDirectory: true)
        try writeComponent(
            at: appURL,
            identifier: "com.vexsign.corpus",
            executableName: "VexCorpus",
            packageType: "APPL"
        )

        // 1. Notification Service Extension
        try writeComponent(
            at: appURL.appendingPathComponent("PlugIns/NotificationService.appex", isDirectory: true),
            identifier: "com.vexsign.corpus.notification",
            executableName: "NotificationService",
            packageType: "XPC!",
            extensionPoint: "com.apple.usernotifications.service"
        )

        // 2. Share Extension
        try writeComponent(
            at: appURL.appendingPathComponent("PlugIns/ShareExtension.appex", isDirectory: true),
            identifier: "com.vexsign.corpus.share",
            executableName: "ShareExtension",
            packageType: "XPC!",
            extensionPoint: "com.apple.share-services"
        )

        // 3. Widget Extension
        try writeComponent(
            at: appURL.appendingPathComponent("PlugIns/StatusWidget.appex", isDirectory: true),
            identifier: "com.vexsign.corpus.widget",
            executableName: "StatusWidget",
            packageType: "XPC!",
            extensionPoint: "com.apple.widgetkit-extension"
        )

        // 4. App Clip
        try writeComponent(
            at: appURL.appendingPathComponent("AppClips/QuickClip.app", isDirectory: true),
            identifier: "com.vexsign.corpus.clip",
            executableName: "QuickClip",
            packageType: "APPL"
        )

        // 5. Watch Application + Nested WatchKit Extension
        try writeComponent(
            at: appURL.appendingPathComponent("Watch/CompanionWatch.app", isDirectory: true),
            identifier: "com.vexsign.corpus.watchkitapp",
            executableName: "CompanionWatch",
            packageType: "APPL",
            platform: 4
        )
        try writeComponent(
            at: appURL.appendingPathComponent(
                "Watch/CompanionWatch.app/PlugIns/CompanionWatchExtension.appex",
                isDirectory: true
            ),
            identifier: "com.vexsign.corpus.watchkitapp.extension",
            executableName: "CompanionWatchExtension",
            packageType: "XPC!",
            extensionPoint: "com.apple.watchkit",
            platform: 4
        )

        // 6. Embedded Framework
        try writeComponent(
            at: appURL.appendingPathComponent("Frameworks/SharedCore.framework", isDirectory: true),
            identifier: "com.vexsign.corpus.SharedCore",
            executableName: "SharedCore",
            packageType: "FMWK",
            fileType: 6
        )

        // 7. Embedded Dynamic Library
        let dylibURL = appURL.appendingPathComponent("Frameworks/libRuntimeHelper.dylib")
        try SigningRegressionFixture.machO(entitlements: nil, fileType: 6).write(to: dylibURL)

        // 8. Nested Helper Application
        try writeComponent(
            at: appURL.appendingPathComponent("Helpers/HelperAgent.app", isDirectory: true),
            identifier: "com.vexsign.corpus.helper",
            executableName: "HelperAgent",
            packageType: "APPL"
        )

        return appURL
    }

    private func makeCandidate(
        id: String,
        pattern: String,
        uuid: String,
        grants: [String: Any] = [:],
        platform: [String] = ["iOS"],
        devices: [String]? = nil,
        allDevices: Bool = true
    ) throws -> SigningProfileCandidate {
        let certDER = SigningRegressionFixture.certificateDER
        let identity = try XCTUnwrap(SigningIdentity(certDER))
        let profile = try SigningRegressionFixture.profile(
            pattern: pattern,
            grants: grants,
            allDevices: allDevices,
            devices: devices,
            certificates: [certDER],
            platform: platform,
            uuid: uuid
        )
        let candidateIdentity = SigningIdentityCandidate(
            reference: "identity://test",
            fingerprint: identity.fingerprint,
            teamIdentifier: SigningRegressionFixture.team,
            displayName: "Corpus Dev Cert",
            notBefore: SigningRegressionFixture.now.addingTimeInterval(-86_400),
            notAfter: SigningRegressionFixture.now.addingTimeInterval(86_400),
            keyAvailability: .accessible,
            nativeSigningSupported: true
        )
        return SigningProfileCandidate(
            id: id,
            identity: candidateIdentity,
            profile: profile,
            isAuthenticated: true,
            authorizedCertificateFingerprints: [identity.fingerprint]
        )
    }

    func testSigningPlanDiscoversAndClassifiesAllNestedComponentTypesDeepestFirst() throws {
        let root = try makeTempRoot("NestedCorpusDiscovery")
        let appURL = try buildFullNestedCorpus(in: root)

        let plan = SigningPlan.make(appBundle: appURL)
        XCTAssertTrue(plan.discoveryIssues.isEmpty, "Unexpected discovery issues: \(plan.discoveryIssues)")
        XCTAssertTrue(
            plan.validationIssues().allSatisfy { $0.severity != .blocking },
            "Unexpected blocking validation issues: \(plan.validationIssues())"
        )

        let byPath = Dictionary(uniqueKeysWithValues: plan.components.map { ($0.path, $0) })
        XCTAssertEqual(byPath["PlugIns/NotificationService.appex"]?.kind, .appExtension)
        XCTAssertEqual(byPath["PlugIns/ShareExtension.appex"]?.kind, .appExtension)
        XCTAssertEqual(byPath["PlugIns/StatusWidget.appex"]?.kind, .appExtension)
        XCTAssertEqual(byPath["AppClips/QuickClip.app"]?.kind, .appClip)
        XCTAssertEqual(byPath["Watch/CompanionWatch.app"]?.kind, .watchApp)
        XCTAssertEqual(
            byPath["Watch/CompanionWatch.app/PlugIns/CompanionWatchExtension.appex"]?.kind,
            .watchExtension
        )
        XCTAssertEqual(byPath["Frameworks/SharedCore.framework"]?.kind, .framework)
        XCTAssertEqual(byPath["Frameworks/libRuntimeHelper.dylib"]?.kind, .dylib)
        XCTAssertEqual(byPath["Helpers/HelperAgent.app"]?.kind, .embeddedApp)

        // Deepest component (WatchKit extension inside Watch app) must be signed before its parent.
        let watchExtIndex = try XCTUnwrap(
            plan.components.firstIndex { $0.path == "Watch/CompanionWatch.app/PlugIns/CompanionWatchExtension.appex" }
        )
        let watchAppIndex = try XCTUnwrap(
            plan.components.firstIndex { $0.path == "Watch/CompanionWatch.app" }
        )
        XCTAssertLessThan(watchExtIndex, watchAppIndex)

        // Frameworks and dylibs must not require separate provisioning profiles.
        let profilePaths = Set(plan.profileBoundComponents.map(\.path))
        XCTAssertFalse(profilePaths.contains("Frameworks/SharedCore.framework"))
        XCTAssertFalse(profilePaths.contains("Frameworks/libRuntimeHelper.dylib"))
        XCTAssertTrue(profilePaths.contains("PlugIns/NotificationService.appex"))
        XCTAssertTrue(profilePaths.contains("PlugIns/ShareExtension.appex"))
        XCTAssertTrue(profilePaths.contains("PlugIns/StatusWidget.appex"))
        XCTAssertTrue(profilePaths.contains("AppClips/QuickClip.app"))
        XCTAssertTrue(profilePaths.contains("Watch/CompanionWatch.app"))
        XCTAssertTrue(profilePaths.contains("Watch/CompanionWatch.app/PlugIns/CompanionWatchExtension.appex"))
        XCTAssertTrue(profilePaths.contains("Helpers/HelperAgent.app"))
    }

    func testMultipleExplicitAndWildcardProfilesResolveAllNestedExtensionsAndTransformEntitlements() throws {
        let team = SigningRegressionFixture.team
        let mainExplicit = try makeCandidate(
            id: "main-explicit",
            pattern: "\(team).com.vexsign.corpus",
            uuid: "11111111-1111-4111-8111-111111111111",
            grants: [
                "com.apple.security.application-groups": ["group.com.vexsign.corpus"],
                "aps-environment": "development"
            ]
        )
        let notifExplicit = try makeCandidate(
            id: "notif-explicit",
            pattern: "\(team).com.vexsign.corpus.notification",
            uuid: "22222222-2222-4222-8222-222222222222",
            grants: ["com.apple.security.application-groups": ["group.com.vexsign.corpus"]]
        )
        let clipExplicit = try makeCandidate(
            id: "clip-explicit",
            pattern: "\(team).com.vexsign.corpus.clip",
            uuid: "33333333-3333-4333-8333-333333333333"
        )
        let wildcard = try makeCandidate(
            id: "wildcard",
            pattern: "\(team).com.vexsign.corpus.*",
            uuid: "44444444-4444-4444-8444-444444444444",
            grants: ["com.apple.security.application-groups": ["group.com.vexsign.corpus"]]
        )
        let watchAppExplicit = try makeCandidate(
            id: "watch-app-explicit",
            pattern: "\(team).com.vexsign.corpus.watchkitapp",
            uuid: "55555555-5555-4555-8555-555555555555",
            platform: ["watchOS"]
        )
        let watchWildcard = try makeCandidate(
            id: "watch-wildcard",
            pattern: "\(team).com.vexsign.corpus.watchkitapp.*",
            uuid: "66666666-6666-4666-8666-666666666666",
            platform: ["watchOS"]
        )

        let targets = [
            BundleSigningTarget(
                relativePath: ".",
                bundleIdentifier: "com.vexsign.corpus",
                platform: "iOS",
                requiredEntitlements: [
                    "com.apple.security.application-groups": ["group.com.vexsign.corpus"],
                    "aps-environment": "development"
                ],
                isolateKeychainGroups: true
            ),
            BundleSigningTarget(
                relativePath: "PlugIns/NotificationService.appex",
                bundleIdentifier: "com.vexsign.corpus.notification",
                platform: "iOS",
                requiredEntitlements: ["com.apple.security.application-groups": ["group.com.vexsign.corpus"]],
                isolateKeychainGroups: true,
                parentBundleIdentifier: "com.vexsign.corpus"
            ),
            BundleSigningTarget(
                relativePath: "PlugIns/ShareExtension.appex",
                bundleIdentifier: "com.vexsign.corpus.share",
                platform: "iOS",
                requiredEntitlements: [:],
                parentBundleIdentifier: "com.vexsign.corpus"
            ),
            BundleSigningTarget(
                relativePath: "PlugIns/StatusWidget.appex",
                bundleIdentifier: "com.vexsign.corpus.widget",
                platform: "iOS",
                requiredEntitlements: ["com.apple.security.application-groups": ["group.com.vexsign.corpus"]],
                parentBundleIdentifier: "com.vexsign.corpus"
            ),
            BundleSigningTarget(
                relativePath: "AppClips/QuickClip.app",
                bundleIdentifier: "com.vexsign.corpus.clip",
                platform: "iOS",
                requiredEntitlements: [:],
                parentBundleIdentifier: "com.vexsign.corpus"
            ),
            BundleSigningTarget(
                relativePath: "Watch/CompanionWatch.app",
                bundleIdentifier: "com.vexsign.corpus.watchkitapp",
                platform: "watchOS",
                requiredEntitlements: [:],
                parentBundleIdentifier: "com.vexsign.corpus"
            ),
            BundleSigningTarget(
                relativePath: "Watch/CompanionWatch.app/PlugIns/CompanionWatchExtension.appex",
                bundleIdentifier: "com.vexsign.corpus.watchkitapp.extension",
                platform: "watchOS",
                requiredEntitlements: [:],
                parentBundleIdentifier: "com.vexsign.corpus.watchkitapp"
            ),
            BundleSigningTarget(
                relativePath: "Helpers/HelperAgent.app",
                bundleIdentifier: "com.vexsign.corpus.helper",
                platform: "iOS",
                requiredEntitlements: [:],
                parentBundleIdentifier: "com.vexsign.corpus"
            )
        ]

        let resolution = CompatibleIdentityResolver.resolve(
            targets: targets,
            candidates: [mainExplicit, notifExplicit, clipExplicit, wildcard, watchAppExplicit, watchWildcard],
            deviceUDID: nil,
            now: SigningRegressionFixture.now
        )

        XCTAssertTrue(resolution.isReady, "All nested components should resolve cleanly: \(resolution.issues)")
        let byPath = Dictionary(uniqueKeysWithValues: resolution.components.map { ($0.target.relativePath, $0) })

        // Explicit profiles beat wildcard profiles where available.
        XCTAssertEqual(byPath["."]?.candidate?.id, "main-explicit")
        XCTAssertEqual(byPath["PlugIns/NotificationService.appex"]?.candidate?.id, "notif-explicit")
        XCTAssertEqual(byPath["AppClips/QuickClip.app"]?.candidate?.id, "clip-explicit")
        XCTAssertEqual(byPath["PlugIns/ShareExtension.appex"]?.candidate?.id, "wildcard")
        XCTAssertEqual(byPath["PlugIns/StatusWidget.appex"]?.candidate?.id, "wildcard")
        XCTAssertEqual(byPath["Helpers/HelperAgent.app"]?.candidate?.id, "wildcard")
        XCTAssertEqual(byPath["Watch/CompanionWatch.app"]?.candidate?.id, "watch-app-explicit")
        XCTAssertEqual(
            byPath["Watch/CompanionWatch.app/PlugIns/CompanionWatchExtension.appex"]?.candidate?.id,
            "watch-wildcard"
        )

        // Entitlement transformations: application-identifier & isolated keychain-access-groups.
        XCTAssertEqual(byPath["."]?.entitlements["application-identifier"] as? String, "\(team).com.vexsign.corpus")
        XCTAssertEqual(
            byPath["."]?.entitlements["keychain-access-groups"] as? [String],
            ["\(team).com.vexsign.corpus"]
        )
        XCTAssertEqual(
            byPath["PlugIns/NotificationService.appex"]?.entitlements["application-identifier"] as? String,
            "\(team).com.vexsign.corpus.notification"
        )
        XCTAssertEqual(
            byPath["PlugIns/NotificationService.appex"]?.entitlements["keychain-access-groups"] as? [String],
            ["\(team).com.vexsign.corpus.notification"]
        )
    }

    func testUnauthorizedNestedExtensionEntitlementFailsWithStructuredDiagnostic() throws {
        let team = SigningRegressionFixture.team
        let wildcard = try makeCandidate(
            id: "wildcard-limited",
            pattern: "\(team).com.vexsign.corpus.*",
            uuid: "66666666-6666-4666-8666-666666666666"
        )
        let target = BundleSigningTarget(
            relativePath: "PlugIns/NotificationService.appex",
            bundleIdentifier: "com.vexsign.corpus.notification",
            platform: "iOS",
            requiredEntitlements: [
                "com.apple.security.application-groups": ["group.com.vexsign.unauthorized"]
            ],
            parentBundleIdentifier: "com.vexsign.corpus"
        )

        let resolution = CompatibleIdentityResolver.resolve(
            targets: [target],
            candidates: [wildcard],
            deviceUDID: nil,
            now: SigningRegressionFixture.now
        )

        XCTAssertFalse(resolution.isReady)
        let diagnostics = resolution.compatibilityDiagnostics
        XCTAssertTrue(
            diagnostics.contains { $0.reason == .entitlementNotAuthorized || $0.reason == .nestedExtensionNotCovered },
            "Unexpected diagnostics: \(diagnostics)"
        )
    }

    func testExtensionsAreNeverAutomaticallyDeletedWithoutExplicitCompatibilityDecision() throws {
        let root = try makeTempRoot("NestedNoSilentDelete")
        let appURL = try buildFullNestedCorpus(in: root)

        // Non-optional extension points and nested apps must NEVER be eligible for automatic removal.
        XCTAssertFalse(try OptionalExtensionPolicy.canRemove("PlugIns/NotificationService.appex", in: appURL))
        XCTAssertFalse(try OptionalExtensionPolicy.canRemove("AppClips/QuickClip.app", in: appURL))
        XCTAssertFalse(try OptionalExtensionPolicy.canRemove("Watch/CompanionWatch.app", in: appURL))
        XCTAssertFalse(
            try OptionalExtensionPolicy.canRemove(
                "Watch/CompanionWatch.app/PlugIns/CompanionWatchExtension.appex",
                in: appURL
            )
        )
        XCTAssertFalse(try OptionalExtensionPolicy.canRemove("Helpers/HelperAgent.app", in: appURL))

        // Unreferenced optional widget/share extensions may be offered only after explicit opt-in.
        XCTAssertTrue(try OptionalExtensionPolicy.canRemove("PlugIns/StatusWidget.appex", in: appURL))
        XCTAssertTrue(try OptionalExtensionPolicy.canRemove("PlugIns/ShareExtension.appex", in: appURL))

        // If the host app references a widget identifier, even that optional extension must NOT be removable.
        try Data("com.vexsign.corpus.widget".utf8)
            .write(to: appURL.appendingPathComponent("WidgetReference.txt"))
        XCTAssertFalse(
            try OptionalExtensionPolicy.canRemove("PlugIns/StatusWidget.appex", in: appURL),
            "An extension referenced by the host app must never be stripped."
        )

        // Without explicit `automaticallyRemoveUncoveredExtensions: true`, uncovered extensions MUST block.
        let mainOnlyProfile = try SigningRegressionFixture.profile(
            pattern: "\(SigningRegressionFixture.team).com.vexsign.corpus",
            certificates: [SigningRegressionFixture.certificateDER]
        )
        let defaultEvaluation = ProfileCompatibility.evaluate(
            profile: mainOnlyProfile,
            target: ProfileCompatibility.Target(
                bundleIdentifier: "com.vexsign.corpus",
                nestedBundleIdentifiers: ["com.vexsign.corpus.widget", "com.vexsign.corpus.notification"],
                automaticallyRemoveUncoveredExtensions: false
            )
        )
        XCTAssertTrue(
            defaultEvaluation.hasBlocking,
            "Uncovered nested extensions must block unless the user makes an explicit compatibility decision."
        )
        XCTAssertTrue(defaultEvaluation.blockingIssues.contains { $0.code == .extensionNotCovered })
    }
}
