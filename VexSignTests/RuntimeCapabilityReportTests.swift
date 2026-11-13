//
//  RuntimeCapabilityReportTests.swift
//  VexSignTests
//
//  The runtime matrix is pure data derived from three flags, so it can be tested without a
//  combined host build, a loaded runtime symbol or a device. What these tests protect is the
//  honesty of the table: an ordinary app must not claim any runtime operation, the guest layout
//  must not claim the native-primary ones, and the operation VexSign does not implement must
//  never come back available.
//

import XCTest
@testable import VexSign

final class RuntimeCapabilityReportTests: XCTestCase {
    private func report(
        guest: Bool = false,
        primary: Bool = false,
        loaded: Bool = true
    ) -> RuntimeCapabilityReport {
        RuntimeCapabilityReport.make(.init(isGuestBuild: guest, isPrimaryHost: primary, runtimeLoaded: loaded))
    }

    // MARK: - Environment identification

    func testEnvironmentIsDerivedFromTheBuildFlags() {
        XCTAssertEqual(RuntimeCapabilityReport.environment(for: .init(isGuestBuild: false, isPrimaryHost: false, runtimeLoaded: false)), .standalone)
        XCTAssertEqual(RuntimeCapabilityReport.environment(for: .init(isGuestBuild: false, isPrimaryHost: true, runtimeLoaded: true)), .combinedNativePrimary)
        XCTAssertEqual(RuntimeCapabilityReport.environment(for: .init(isGuestBuild: true, isPrimaryHost: false, runtimeLoaded: true)), .combinedGuestPrototype)
        // Loaded with neither flag: a combined package whose metadata is wrong. It is reported
        // as unidentified rather than guessed into a layout.
        XCTAssertEqual(RuntimeCapabilityReport.environment(for: .init(isGuestBuild: false, isPrimaryHost: false, runtimeLoaded: true)), .combinedUnidentified)
    }

    func testGuestFlagWinsWhenBothFlagsAreSet() {
        // The guest layout replaces the entry point; the primary flag is then decoration, and
        // reporting the native-primary matrix would advertise hooks this process never installs.
        XCTAssertEqual(RuntimeCapabilityReport.environment(for: .init(isGuestBuild: true, isPrimaryHost: true, runtimeLoaded: true)), .combinedGuestPrototype)
    }

    // MARK: - Ordinary app

    func testTheOrdinaryAppReachesNoRuntimeOperation() {
        let report = report(loaded: false)
        XCTAssertEqual(report.environment, .standalone)
        for operation in RuntimeCapabilityReport.Operation.allCases where operation != .externalAppHandoff {
            XCTAssertFalse(report.isAvailable(operation), "\(operation) must not be reachable from the ordinary app")
            XCTAssertEqual(report.reason(for: operation), .runtimeNotLoaded)
        }
    }

    func testExternalHandoffIsUnsupportedInEveryLayout() {
        // VexSign reaches the runtime it was built with. A registered URL handler is not
        // evidence that another container would accept an import, so this never becomes true.
        let layouts: [(Bool, Bool, Bool)] = [(false, false, false), (false, true, true), (true, false, true), (false, false, true)]
        for (guest, primary, loaded) in layouts {
            let report = report(guest: guest, primary: primary, loaded: loaded)
            XCTAssertFalse(report.isAvailable(.externalAppHandoff))
            XCTAssertEqual(report.reason(for: .externalAppHandoff), .unsupportedByDesign)
        }
    }

    // MARK: - Combined layouts

    func testNativePrimaryReachesHostOperationsButNotGuestHooks() {
        let report = report(primary: true)
        XCTAssertEqual(report.environment, .combinedNativePrimary)
        XCTAssertTrue(report.isAvailable(.embeddedContainerUI))
        XCTAssertTrue(report.isAvailable(.embeddedSideStoreSession))
        XCTAssertTrue(report.isAvailable(.guestImportStaging))
        XCTAssertTrue(report.isAvailable(.sessionSwitch))
        XCTAssertTrue(report.isAvailable(.scheduledGuestTasks))
        XCTAssertFalse(report.isAvailable(.guestKeychainHooks))
        XCTAssertEqual(report.reason(for: .guestKeychainHooks), .notPartOfThisLayout)
    }

    func testGuestPrototypeInstallsHooksAndCannotRegisterHostTasks() {
        let report = report(guest: true)
        XCTAssertEqual(report.environment, .combinedGuestPrototype)
        XCTAssertTrue(report.isAvailable(.guestKeychainHooks))
        XCTAssertTrue(report.isAvailable(.guestImportStaging))
        XCTAssertFalse(report.isAvailable(.scheduledGuestTasks))
        XCTAssertEqual(report.reason(for: .scheduledGuestTasks), .notPartOfThisLayout)
    }

    func testHooksAndHostTasksAreMutuallyExclusive() {
        for (guest, primary) in [(false, true), (true, false), (false, false)] {
            let report = report(guest: guest, primary: primary)
            XCTAssertNotEqual(
                report.isAvailable(.guestKeychainHooks),
                report.isAvailable(.scheduledGuestTasks),
                "guest=\(guest) primary=\(primary): a build must not claim both keychain hooks and host tasks"
            )
        }
    }

    // MARK: - Nothing is available without the host

    func testNoOperationIsAvailableWhenTheRuntimeIsNotLoaded() {
        for guest in [false, true] {
            for primary in [false, true] {
                let report = report(guest: guest, primary: primary, loaded: false)
                for operation in RuntimeCapabilityReport.Operation.allCases {
                    XCTAssertFalse(report.isAvailable(operation), "\(operation) claimed without a loaded runtime")
                }
            }
        }
    }

    // MARK: - Session switch warning

    func testSessionSwitchWarningExistsOnlyWhenTheSwitchIsReachable() {
        XCTAssertNil(report(loaded: false).sessionSwitchWarning)
        XCTAssertNotNil(report(primary: true).sessionSwitchWarning)
    }

    // MARK: - Diagnostics

    func testDiagnosticsExportDescribesEveryOperationWithoutFreeText() {
        let report = report(primary: true)
        let json = report.jsonObject
        XCTAssertEqual(json["environment"] as? String, "combinedNativePrimary")
        guard let operations = json["operations"] as? [String: String] else {
            return XCTFail("operations must be a flat string map")
        }
        XCTAssertEqual(operations.count, RuntimeCapabilityReport.Operation.allCases.count)
        for operation in RuntimeCapabilityReport.Operation.allCases {
            let value = operations[operation.rawValue]
            XCTAssertNotNil(value, "\(operation) is missing from the export")
            // Only the two documented shapes: no paths, names or bundle identifiers.
            XCTAssertTrue(value == "available" || value?.hasPrefix("unavailable:") == true, "unexpected value \(value ?? "nil")")
        }
        XCTAssertEqual(operations["guestKeychainHooks"], "unavailable:notPartOfThisLayout")
        XCTAssertEqual(operations["externalAppHandoff"], "unavailable:unsupportedByDesign")
    }
}
