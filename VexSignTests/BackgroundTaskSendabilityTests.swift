// The background-task types are shared across threads, but only some of them can carry a compiler-
// checked `Sendable` conformance. This file records which, so a later "tidy up" cannot quietly add
// the `@unchecked` escapes the branch deliberately avoided.
//
// These assertions are compile-time facts expressed as tests: removing one of the conformances
// listed below stops this file compiling, which is the point. Absence cannot be asserted (see the
// note on the class), so the un-conformed types are documented instead.
import Foundation
import XCTest
@testable import VexSign

/// `BackgroundTaskCompletionGate` and `BackgroundTaskOwnership` are shared across threads but
/// carry no conformance: the gate's completion closure captures a `BGTask`, which the SDK does
/// not mark `Sendable`, so a conformance would have to be `@unchecked` — a new escape in the
/// tracked baseline (`tools/concurrency-baseline.json`), which this branch must not add.
///
/// They are still safe to share. That safety is by construction, not by conformance:
///
/// - the gate protects its single `Outcome` with `OSAllocatedUnfairLock`;
/// - ownership protects its single claim with `BackgroundWorkCompletionFlag`, also locked;
/// - `BackgroundWorkCancellation`, which *is* `Sendable`, is the only one handed across the
///   actor boundary directly.
final class BackgroundTaskSendabilityTests: XCTestCase {
    /// A generic constraint is the cheapest way to ask the compiler "does this conform?" at compile
    /// time rather than at run time.
    private func requireSendable<T: Sendable>(_ type: T.Type) {}

    func testValueTypesCrossActorBoundariesSafely() {
        requireSendable(BackgroundDownloadWork.self)
        requireSendable(BackgroundTaskCompletionGate.Outcome.self)
        requireSendable(BackgroundTaskCompletionGate.Source.self)
        requireSendable(BackgroundWorkCancellation.self)
        requireSendable(BackgroundWorkCompletionFlag.self)
        requireSendable(LibrarySizeMeasurementKey.self)
        requireSendable(LibrarySizeMeasurementKey.Entry.self)
    }
}
