import Foundation
import os

/// The one place a `BGTask` is allowed to be completed from.
///
/// `BGTaskScheduler` requires exactly one `setTaskCompleted(success:)` call per task. The old
/// background-download handlers had two writers: the expiration handler and the monitoring worker.
/// Expiration could report failure and then the worker would report success a second time, so the
/// system saw a contradictory outcome and the download work kept running untracked.
///
/// A gate makes the rule structural rather than a convention: the first `finish(success:)` wins and
/// every later attempt is counted as an ignored duplicate. Expiration is not a second completion
/// path either — it cancels the monitor, and whichever party reaches the gate first decides the
/// result.
///
/// ## Thread safety
///
/// State lives in an `OSAllocatedUnfairLock`, so concurrent calls from a worker and from an
/// expiration handler cannot corrupt it. That is required here: a `BGTaskScheduler` expiration
/// handler is neither async nor guaranteed to run on the main actor, so completion has to be
/// callable synchronously from any thread. `complete` is invoked *after* the lock is released,
/// because `setTaskCompleted` can re-enter this code on another queue.
///
/// The type is deliberately not declared `Sendable`. Its `complete` closure captures the `BGTask`,
/// which the SDK does not mark `Sendable`, so a conformance here would be `@unchecked` — and this
/// repository treats that as a tracked exception rather than a convenience (see
/// `Tools/Development/concurrency-discipline.py`). The lock makes the sharing safe; the conformance is a
/// decision for the Swift 6 migration, when the completion closure can be reworked to carry a
/// `Sendable` handle instead.
final class BackgroundTaskCompletionGate {
    struct Outcome: Equatable, Sendable {
        /// The argument passed to `setTaskCompleted(success:)`. `nil` until the gate closes.
        var success: Bool?
        /// `true` when the system expired the task instead of the work finishing.
        var expired = false
        /// Which party closed the gate. Diagnostic only.
        var source: Source?
        /// How many later completions were dropped. Diagnostic only.
        var ignoredCompletions = 0

        var isClosed: Bool { success != nil }
    }

    enum Source: String, Equatable, Sendable {
        case worker, expiration
    }

    private let complete: (Bool) -> Void
    private let state = OSAllocatedUnfairLock(initialState: Outcome())

    /// - Parameter complete: the underlying `BGTask.setTaskCompleted(success:)` call. Supplied by
    ///   the app so this type stays testable without a real `BGTask`.
    init(complete: @escaping (Bool) -> Void) {
        self.complete = complete
    }

    /// Completes the task. Only the first call reaches `setTaskCompleted`; returns `true` when this
    /// call closed the gate and `false` when it was dropped as a duplicate.
    @discardableResult
    func finish(success: Bool, source: Source = .worker) -> Bool {
        let claimed = state.withLock { outcome -> Bool in
            guard !outcome.isClosed else {
                outcome.ignoredCompletions += 1
                return false
            }
            outcome.success = success
            outcome.source = source
            return true
        }
        guard claimed else { return false }

        complete(success)
        return true
    }

    /// Records that the system expired the task, then closes the gate with failure.
    ///
    /// Idempotent, and deliberately unable to override a worker result that already landed: if the
    /// worker finished first, expiration is a no-op and the worker's success stands.
    @discardableResult
    func expire() -> Bool {
        let shouldComplete = state.withLock { outcome -> Bool in
            guard !outcome.expired else { return false }
            outcome.expired = true
            // A worker that already closed the gate keeps its result.
            return !outcome.isClosed
        }
        guard shouldComplete else { return false }

        return finish(success: false, source: .expiration)
    }

    var currentOutcome: Outcome {
        state.withLock { $0 }
    }
}
