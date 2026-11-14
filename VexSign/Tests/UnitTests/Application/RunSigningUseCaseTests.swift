import Foundation
import XCTest
@testable import VexSign

/// Exercises Application policy with value types only: no Core Data object,
/// UIKit request, native engine, signing identity, or installation side effect.
final class RunSigningUseCaseTests: XCTestCase {
    private typealias Event = SigningWorkflowEvent<String>
    private enum Failure: Error { case refused }

    private struct Work: SigningWork {
        let events: [Event]
        let result: Result<String, Error>

        func run(_ request: String, reporting: @escaping (Event) -> Void) async -> Result<String, Error> {
            events.forEach(reporting)
            return result
        }
    }

    func testProgressKeepsOrderAndOnlyTheUseCaseEmitsTheVerdict() async {
        let work = Work(events: [
            .stage(.copying), .failed(Failure.refused), .signatureVerified,
            .finished("untrusted verdict"), .compatibilityRemoved(["Widget.appex"])
        ], result: .success("registered artifact"))
        var events: [Event] = []

        await RunSigningUseCase(work: work).execute("request") { events.append($0) }

        XCTAssertEqual(events.map(Self.label), [
            "copying", "verified", "compatibility:Widget.appex", "finished:registered artifact"
        ])
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
    }

    func testArtifactSuccessDoesNotInventSignatureVerification() async {
        let work = Work(events: [.stage(.modifying), .stage(.registering)], result: .success("artifact"))
        var events: [Event] = []

        await RunSigningUseCase(work: work).execute("request") { events.append($0) }

        XCTAssertEqual(events.map(Self.label), ["modifying", "registering", "finished:artifact"])
    }

    func testFailurePreservesTheErrorAndHasOneTerminalEvent() async {
        let work = Work(events: [.stage(.verifying)], result: .failure(Failure.refused))
        var events: [Event] = []

        await RunSigningUseCase(work: work).execute("request") { events.append($0) }

        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
        guard case .failed(let error)? = events.last else { return XCTFail("Expected failure") }
        guard let failure = error as? Failure, case .refused = failure else {
            return XCTFail("Original error was not preserved")
        }
    }

    func testPipelineCancellationIsNotReportedAsFailure() async {
        let work = Work(events: [.stage(.copying)], result: .failure(CancellationError()))
        var events: [Event] = []

        await RunSigningUseCase(work: work).execute("request") { events.append($0) }

        XCTAssertEqual(events.map(Self.label), ["copying", "cancelled"])
    }

    func testCancellationBeforeStartNeverInvokesWork() async {
        // Children added to a cancelled group start cancelled. This avoids a
        // sleep/race between cancel() and the use case's admission check.
        let labels = await withTaskGroup(of: [String].self) { group in
            group.cancelAll()
            group.addTask {
                let work = Work(events: [.stage(.copying)], result: .success("must not run"))
                var labels: [String] = []
                await RunSigningUseCase(work: work).execute("request") { labels.append(Self.label($0)) }
                return labels
            }
            return await group.next() ?? []
        }
        XCTAssertEqual(labels, ["cancelled"])
    }

    private static func label(_ event: Event) -> String {
        switch event {
        case .stage(let stage): stage.rawValue
        case .signatureVerified: "verified"
        case .compatibilityRemoved(let components): "compatibility:" + components.joined(separator: ",")
        case .finished(let artifact): "finished:" + artifact
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }
}
