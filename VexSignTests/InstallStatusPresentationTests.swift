// Lifecycle and transport evidence must share the same presentation rules.
import Foundation
import IDeviceSwift
import NimbleExtensions
import XCTest
@testable import VexSign

final class InstallStatusPresentationTests: XCTestCase {
    private func resolve(_ status: InstallerStatusViewModel.InstallerStatus,
                         _ phase: InstallConfirmation.Phase) -> InstallPresentation {
        InstallPresentation.resolve(status: status, phase: phase, taskPhase: nil, isExport: false)
    }

    func testWaitingForIOSDoesNotSayReady() {
        let state = resolve(.ready, .waitingForStart)
        XCTAssertEqual(state, .awaitingConfirmation)
        XCTAssertNotEqual(state.label(), String.localized("Ready"))
    }

    func testVerificationOverridesStaleTransport() {
        for status in [.ready, .sendingPayload, .installing, .none] as [InstallerStatusViewModel.InstallerStatus] {
            XCTAssertEqual(resolve(status, .verifying), .verifying)
            XCTAssertEqual(resolve(status, .verifying).label(verificationAttempt: 4),
                           InstallVerificationPolicy.statusLabel(attempt: 4))
        }
    }

    func testProgressRequiresCounterOrConfirmedCompletion() {
        func percentage(_ phase: InstallConfirmation.Phase, _ progress: Double, _ completed: Bool = false) -> Int? {
            InstallerStatusViewModel.displayedPercentage(phase: phase, overall: progress, isCompleted: completed)
        }
        XCTAssertNil(percentage(.waitingForStart, 0.4))
        XCTAssertNil(percentage(.verifying, 0.99))
        XCTAssertEqual(percentage(.downloading, 0.42), 42)
        XCTAssertEqual(percentage(.downloading, 0.999), 99)
        XCTAssertEqual(percentage(.finished(.installed), 1, true), 100)
    }

    func testTransportCompletionDoesNotProveInstall() {
        XCTAssertEqual(resolve(.completed(.success(())), .waitingForStart), .verifying)
        XCTAssertEqual(resolve(.completed(.success(())), .finished(.installed)), .installed)
        XCTAssertEqual(resolve(.ready, .finished(.installedOtherVersion("2.0"))), .unconfirmed)
        XCTAssertEqual(resolve(.ready, .finished(.timedOutVerifying)), .unconfirmed)
        XCTAssertEqual(resolve(.broken(NSError(domain: "test", code: 1)), .verifying), .failed)
    }
}
