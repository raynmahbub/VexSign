import Foundation
import XCTest
@testable import VexSign

final class DiagnosticEventTests: XCTestCase {
    func testEventIsSanitizedBeforeItCanBeStored() {
        let event = DiagnosticEvent.make(
            code: DiagnosticEventCode.signFailed,
            severity: .error,
            category: .signing,
            operationID: "op-1234",
            userMessage: "Sign failed token=supersecret123",
            developerDetail: "password=hunter2 on line 4",
            recoverySuggestion: "Check signing options, then retry.",
            metadata: [
                "host": "https://example.com/private/path",
                "bad key": "dropped",
                "stage": "codesign"
            ]
        )

        XCTAssertFalse(event.userMessage.contains("supersecret123"))
        XCTAssertFalse((event.developerDetail ?? "").contains("hunter2"))
        XCTAssertEqual(event.subsystem, "app.vexsign.signing")
        XCTAssertEqual(event.operationID, "op-1234")
        XCTAssertNil(event.metadata["bad key"])
        XCTAssertEqual(event.metadata["stage"], "codesign")
        XCTAssertTrue(event.userMessage.count <= DiagnosticEventSanitizer.maximumTextLength)
    }

    func testUnsafeOperationIDsAreDropped() {
        let event = DiagnosticEvent.make(
            code: "VEX-TEST-001",
            severity: .warning,
            category: .app,
            operationID: "not a safe id/private/path",
            userMessage: "Recorded."
        )
        XCTAssertNil(event.operationID)
    }

    func testStableDiagnosticCodesAreUnique() {
        let codes = [
            DiagnosticEventCode.appLaunched, .appHealth,
            .signFailed, .signSucceeded,
            .importFailed, .importSucceeded,
            .downloadFailed, .downloadSucceeded,
            .networkFailure, .deviceFailure,
            .installFailed, .installUnconfirmed,
            .taskFailed, .taskCancelled,
            .backgroundFailure, .automationFailure,
            .securityFailure, .storageFailure,
            .diagnosticStoreRecovered, .performanceMeasurement,
            .metricKitCrash, .metricKitHang, .metricKitCPU, .metricKitLaunch, .metricKitDisk
        ]
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertTrue(codes.allSatisfy { $0.hasPrefix("VEX-") })
    }

    func testHardwareFailureEventCarriesSanitizedTriageFields() {
        let event = DiagnosticEvent.deviceFailure(
            operationID: "device-op-1",
            operationType: "install",
            connectionState: "connected",
            failureCategory: "deviceUnreachable",
            systemErrorCode: "OS status=-402620415 UDID=12345678-ABCDEFGH",
            durationMs: 4200,
            recoveryOutcome: "Unlock the device and reconnect.",
            deviceModel: "iPhone16,2",
            osVersion: "18.2",
            userMessage: "Installation failed for token=supersecret123"
        )
        XCTAssertEqual(event.code, DiagnosticEventCode.deviceFailure)
        XCTAssertEqual(event.category, .device)
        XCTAssertEqual(event.operationID, "device-op-1")
        XCTAssertEqual(event.metadata["operationType"], "install")
        XCTAssertEqual(event.metadata["connectionState"], "connected")
        XCTAssertEqual(event.metadata["durationMs"], "4200")
        XCTAssertEqual(event.metadata["appVersion"], VexSignBuildInfo.version)
        XCTAssertLessThanOrEqual(event.metadata.count, DiagnosticEventSanitizer.maximumMetadataEntries)
        XCTAssertFalse(event.userMessage.contains("supersecret123"))
        XCTAssertFalse((event.developerDetail ?? "").contains("12345678-ABCDEFGH"))
        XCTAssertFalse(event.metadata.values.contains { $0.contains("12345678-ABCDEFGH") })
    }

    func testVexSignErrorLogDescriptionIsRedacted() {
        let error = VexSignError(
            .signingFailed,
            message: "Sign failed token=supersecret123",
            context: ["password": "hunter2"]
        )
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.contains("supersecret123"))
        XCTAssertFalse(description.contains("hunter2"))
    }

    func testRecoveryGuidanceMapsRepresentativeErrorCodes() {
        // VexSignError.Code is intentionally not CaseIterable in production;
        // these cover every recovery branch, including the fallback.
        let codes: [VexSignError.Code] = [
            .certificateExpired, .certificatePasswordInvalid, .signingFailed,
            .deviceUnreachable, .installationUnconfirmed, .downloadFailed,
            .downloadSizeExceeded, .archiveInvalid, .sourceUnreachable,
            .networkTimeout, .backupCorrupt, .permissionDenied, .storeCorrupt,
            .tweakNotFound, .operationCancelled, .unknown
        ]
        for code in codes {
            let suggestion = DiagnosticRecoveryGuide.suggestion(for: code)
            XCTAssertFalse(suggestion.isEmpty)
            XCTAssertFalse(suggestion.contains("<redacted>"))
        }
    }

    func testOutcomeBridgePreservesCorrelationAndMeasuredDuration() async {
        let started = Date().addingTimeInterval(-3)
        let outcome = OperationOutcomeRecord(
            correlationID: "11111111-2222-3333-4444-555555555555",
            operation: "sign",
            stage: "signing",
            status: .failed,
            reason: "token=supersecret123",
            startedAt: started,
            finishedAt: Date()
        )
        let event = DiagnosticEvent.fromOutcome(outcome, category: .signing)
        XCTAssertEqual(event.operationID, outcome.correlationID)
        XCTAssertEqual(event.code, DiagnosticEventCode.signFailed)
        XCTAssertEqual(event.metadata["operation"], "sign")
        XCTAssertFalse((event.developerDetail ?? "").contains("supersecret123"))
        XCTAssertGreaterThan(Double(event.metadata["durationMs"] ?? "0") ?? 0, 0)
    }
}

