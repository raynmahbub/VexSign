// Apple Account lifecycle policy tests. Pure rules only: no Apple account,
// portal mutation, key export, signing or installation is simulated here.
import Foundation
import XCTest
@testable import VexSign

final class AppleAccountLifecyclePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func observation(apps: Int? = 0, devices: Int? = 0,
                             source: AppleAccountLimitSource = .applePortalPreflight) -> AppleAccountPortalObservation {
        AppleAccountPortalObservation(activeAppIdentifierCount: apps,
                                      registeredDeviceCount: devices, source: source)
    }

    func testMembershipMappingAndRenewalMode() {
        XCTAssertEqual(AppleAccountKind(.free), .free)
        XCTAssertEqual(AppleAccountKind(.paidVerified), .paidVerified)
        XCTAssertEqual(AppleAccountKind(.developerProgramUnverified), .unverified)
        XCTAssertTrue(AppleAccountKind.free.canProvision)
        XCTAssertTrue(AppleAccountKind.paidVerified.canProvision)
        XCTAssertFalse(AppleAccountKind.unverified.canProvision)
        XCTAssertEqual(AppleAccountKind.free.maximumRegisteredAppIdentifiers, 10)
        XCTAssertEqual(AppleAccountKind.free.maximumRegisteredDevices, 3)
        XCTAssertEqual(AppleAccountKind.free.maximumInstalledAppsPerDevice, 3)
        XCTAssertEqual(AppleAccountKind.free.expectedProfileLifetimeDays, 7)
        XCTAssertNil(AppleAccountKind.paidVerified.maximumRegisteredAppIdentifiers)
        XCTAssertEqual(AppleAccountLifecyclePolicy.renewalMode(for: .free), .attendedManual)
        XCTAssertEqual(AppleAccountLifecyclePolicy.renewalMode(for: .paidVerified), .attendedManual)
        XCTAssertEqual(AppleAccountLifecyclePolicy.renewalMode(for: .unverified), .unavailable)
    }

    func testLimitsCarrySourceValidityAndDocumentation() {
        let limits = AppleAccountLifecyclePolicy.limits(for: .free)
        XCTAssertEqual(limits.registeredAppIdentifiers.maximum, 10)
        XCTAssertEqual(limits.registeredAppIdentifiers.source, .applePersonalTeamDocumentation)
        XCTAssertEqual(limits.registeredDevices.maximum, 3)
        XCTAssertEqual(limits.profileLifetimeDays.maximum, 7)
        XCTAssertEqual(limits.documentationURL,
                       "https://developer.apple.com/help/account/basics/about-your-developer-account/")
        XCTAssertTrue(limits.appIdentifierSummary.contains("10"))
        XCTAssertTrue(limits.appIdentifierSummary.contains(limits.registeredAppIdentifiers.validity))
        XCTAssertTrue(limits.deviceSummary.contains("3"))
        XCTAssertFalse(limits.registeredAppIdentifiers.validity.isEmpty)

        let paid = AppleAccountLifecyclePolicy.limits(for: .paidVerified)
        XCTAssertNil(paid.registeredAppIdentifiers.maximum)
        XCTAssertEqual(paid.registeredAppIdentifiers.source, .unknown)
        XCTAssertNil(paid.documentationURL)
        XCTAssertTrue(paid.appIdentifierSummary.contains("no free-account") ||
                      paid.appIdentifierSummary.contains("No free-account"))
    }

    func testFreeAccountAllowsTheTenthAppButRefusesTheEleventh() throws {
        try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
            observation: observation(apps: 9), requestedAlreadyActive: false,
            newAppIdentifierCount: 1, requiresDeviceRegistration: false)
        XCTAssertThrowsError(
            try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
                observation: observation(apps: 10), requestedAlreadyActive: false,
                newAppIdentifierCount: 1, requiresDeviceRegistration: false)
        ) { error in
            XCTAssertEqual(error as? AppleAccountLifecycleError, .freeAppIdentifierLimit)
        }
        XCTAssertThrowsError(
            try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
                observation: observation(apps: 9), requestedAlreadyActive: false,
                newAppIdentifierCount: 2, requiresDeviceRegistration: false)
        ) { error in
            XCTAssertEqual(error as? AppleAccountLifecycleError, .freeAppIdentifierLimit)
        }
    }

    func testRenewingAnExistingFreeAppDoesNotConsumeAnotherSlot() throws {
        try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
            observation: observation(apps: 10, devices: 3),
            requestedAlreadyActive: true, newAppIdentifierCount: 0,
            requiresDeviceRegistration: false)
    }

    func testFreeDeviceRegistrationLimitIsCheckedBeforeMutation() {
        XCTAssertNoThrow(
            try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
                observation: observation(devices: 2), requestedAlreadyActive: true,
                newAppIdentifierCount: 0, requiresDeviceRegistration: true)
        )
        XCTAssertThrowsError(
            try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
                observation: observation(devices: 3), requestedAlreadyActive: true,
                newAppIdentifierCount: 0, requiresDeviceRegistration: true)
        ) { error in
            XCTAssertEqual(error as? AppleAccountLifecycleError, .freeDeviceLimit)
        }
    }

    func testUnobservedOrNonPortalCountsFailClosedForNewRegistration() {
        XCTAssertThrowsError(
            try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
                observation: observation(apps: nil), requestedAlreadyActive: false,
                newAppIdentifierCount: 1, requiresDeviceRegistration: false)
        ) { error in
            XCTAssertEqual(error as? AppleAccountLifecycleError, .inventoryUnavailable)
        }
        XCTAssertThrowsError(
            try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
                observation: observation(apps: 0, devices: 0, source: .applePersonalTeamDocumentation),
                requestedAlreadyActive: false, newAppIdentifierCount: 1,
                requiresDeviceRegistration: false)
        ) { error in
            XCTAssertEqual(error as? AppleAccountLifecycleError, .inventoryUnavailable)
        }
        XCTAssertThrowsError(
            try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
                observation: observation(devices: nil), requestedAlreadyActive: true,
                newAppIdentifierCount: 0, requiresDeviceRegistration: true)
        ) { error in
            XCTAssertEqual(error as? AppleAccountLifecycleError, .inventoryUnavailable)
        }
        XCTAssertNoThrow(
            try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
                observation: observation(apps: nil, devices: nil),
                requestedAlreadyActive: true, newAppIdentifierCount: 0,
                requiresDeviceRegistration: false)
        )
    }

    func testPaidVerifiedMembershipHasNoLocalFreeCeiling() throws {
        try AppleAccountLifecyclePolicy.requireProvisioning(kind: .paidVerified,
            observation: observation(apps: nil, devices: nil),
            requestedAlreadyActive: false, newAppIdentifierCount: 12,
            requiresDeviceRegistration: true)
    }

    func testUnverifiedMembershipAndImpossibleCountsAreRejected() {
        XCTAssertThrowsError(
            try AppleAccountLifecyclePolicy.requireProvisioning(kind: .unverified,
                observation: observation(), requestedAlreadyActive: false,
                newAppIdentifierCount: 1, requiresDeviceRegistration: false)
        ) { error in
            XCTAssertEqual(error as? AppleAccountLifecycleError, .unverifiedMembership)
        }
        for count in [-1, 1001, Int.min] {
            XCTAssertThrowsError(
                try AppleAccountLifecyclePolicy.requireProvisioning(kind: .paidVerified,
                    observation: observation(apps: count), requestedAlreadyActive: false,
                    newAppIdentifierCount: 1, requiresDeviceRegistration: false)
            ) { error in
                XCTAssertEqual(error as? AppleAccountLifecycleError, .invalidCount)
            }
        }
        XCTAssertThrowsError(
            try AppleAccountLifecyclePolicy.requireProvisioning(kind: .free,
                observation: observation(), requestedAlreadyActive: false,
                newAppIdentifierCount: -1, requiresDeviceRegistration: false)
        ) { error in
            XCTAssertEqual(error as? AppleAccountLifecycleError, .invalidCount)
        }
    }

    func testProfileLifetimeClassificationIsAdvisoryAndBounded() {
        let sevenDays = now.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(AppleAccountLifecyclePolicy.profileLifetime(
            kind: .free, expiresAt: sevenDays, now: now), .withinExpected)
        XCTAssertEqual(AppleAccountLifecyclePolicy.profileLifetime(
            kind: .free, expiresAt: now.addingTimeInterval(30 * 86_400), now: now),
            .longerThanExpected)
        XCTAssertEqual(AppleAccountLifecyclePolicy.profileLifetime(
            kind: .free, expiresAt: now, now: now), .invalid)
        XCTAssertEqual(AppleAccountLifecyclePolicy.profileLifetime(
            kind: .free, expiresAt: Date.distantFuture, now: now), .invalid)
        XCTAssertEqual(AppleAccountLifecyclePolicy.profileLifetime(
            kind: .paidVerified, expiresAt: now.addingTimeInterval(365 * 86_400), now: now),
            .withinExpected)
        XCTAssertTrue(AppleAccountProfileLifetime.longerThanExpected.isUsableForHandoff)
        XCTAssertFalse(AppleAccountProfileLifetime.invalid.isUsableForHandoff)
    }

    func testEveryRejectionCarriesAnActionableSentence() {
        for error in [AppleAccountLifecycleError.unverifiedMembership, .inventoryUnavailable,
                      .freeAppIdentifierLimit, .freeDeviceLimit, .invalidAppIdentifier, .invalidCount] {
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.hasSuffix("."), message)
        }
    }
}
