import Foundation
import os

extension Duration {
    /// Seconds as a `Double`.
    ///
    /// `Duration` keeps attoseconds, which are irrelevant for a timeout budget measured in minutes;
    /// seconds plus sub-second precision is enough and keeps the loop free of component math.
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Cancellation-preserving sleep used instead of `Thread.sleep`.
///
/// `Task.sleep(for:)` is the right primitive, but it throws on cancellation. Wrapping it here keeps
/// the throw explicit at the call site so the monitor loop cannot mistake "cancelled" for "slept
/// fine", which is the bug that `while !wasExpired` polling used to hide.
func sleepForBackgroundPolling(_ interval: TimeInterval) async throws {
    try await Task.sleep(for: .seconds(interval))
}

/// An immutable sample of download work, taken on the main actor.
///
/// The background handlers used to read `DownloadManager.shared.downloads` from a global queue.
/// `downloads` is `@Published` state on an `ObservableObject`, and `Download` itself is a mutable
/// `@unchecked Sendable` class, so handing that array to a worker queue was an unsynchronised read
/// of state the main thread writes. Nothing here escapes: the sample is copied on the main actor and
/// every field is a value, so readers cannot observe a download mutating underneath them.
struct BackgroundDownloadWork: Equatable, Sendable {
    /// Every download row currently held by the manager, finished or not.
    var itemCount: Int
    /// Downloads making progress right now.
    var activeCount: Int
    /// Mean progress of the active downloads, `0...1`. `1` when nothing is active.
    var averageProgress: Double
    /// The manager's own answer to "is there work left", so this cannot disagree with the UI.
    var hasUnfinishedWork: Bool

    static let idle = BackgroundDownloadWork(
        itemCount: 0,
        activeCount: 0,
        averageProgress: 1,
        hasUnfinishedWork: false
    )

    /// `true` when the background task has nothing left to keep alive for.
    var isFinished: Bool { activeCount == 0 && !hasUnfinishedWork }

    /// `0...100`, for `BGTask.progress.completedUnitCount`.
    ///
    /// Clamped to `99` while any work remains. With no active transfer, `averageProgress` defaults
    /// to `1`, so the unclamped value was 100 — reporting a task as complete while verifying,
    /// importing or signing was still running. The progress counter is informational and this
    /// cannot prove anything, but a full bar next to a spinning task is a lie the user can see.
    var completedPercent: Int64 {
        guard !isFinished else { return 100 }
        let clamped = min(max(averageProgress, 0), 1)
        return min(99, Int64((clamped * 100).rounded()))
    }
}

/// What the background handler needs from the download system, and nothing more.
///
/// `@MainActor` on purpose: the imported state lives there, so the isolation is the contract rather
/// than a comment asking callers to remember it. A test double is a plain `@MainActor` type — no
/// second manager, which is what the architecture notes forbid.
@MainActor
protocol BackgroundDownloadMonitoring: AnyObject {
    func currentWork() -> BackgroundDownloadWork
    func resumeAll()
    func pauseAll()
}

/// The production monitor: copies only values out of `DownloadManager` and never returns a
/// `Download` reference across the actor boundary.
@MainActor
final class DownloadManagerBackgroundMonitor: BackgroundDownloadMonitoring {
    private let manager: DownloadManager

    init(manager: DownloadManager = .shared) {
        self.manager = manager
    }

    func currentWork() -> BackgroundDownloadWork {
        let downloads = manager.downloads
        // The same predicate the previous inline filters used, kept in one place so the
        // continued-processing and processing paths cannot drift apart.
        let active = downloads.filter {
            $0.isActive || ($0.progress > 0 && $0.progress < 1.0 && !$0.isPaused)
        }
        let average: Double
        if active.isEmpty {
            average = 1
        } else {
            average = active.reduce(0.0) { $0 + $1.progress } / Double(active.count)
        }
        return BackgroundDownloadWork(
            itemCount: downloads.count,
            activeCount: active.count,
            averageProgress: average,
            hasUnfinishedWork: manager.hasUnfinishedWork
        )
    }

    func resumeAll() {
        manager.resumeAllDownloads()
    }

    func pauseAll() {
        manager.pauseAllDownloads()
    }
}

/// The decision the monitor loop makes each tick. Pure, so the boundary cases are unit-testable
/// without a real background task.
enum BackgroundDownloadMonitorPolicy {
    enum Decision: Equatable {
        /// Nothing left to wait for — report success.
        case finished
        /// Out of background time — report the truth about whether work was left behind.
        case timedOut(workRemaining: Bool)
        /// Sleep, then sample again.
        case keepMonitoring
    }

    static func decide(work: BackgroundDownloadWork, elapsed: TimeInterval, timeout: TimeInterval) -> Decision {
        // Idle beats the deadline: a task that finished exactly at the buzzer succeeded.
        if work.isFinished { return .finished }
        if elapsed >= timeout { return .timedOut(workRemaining: work.hasUnfinishedWork) }
        return .keepMonitoring
    }
}

/// Holds the monitoring task so the non-async expiration handler can cancel it.
///
/// Expiration can fire before `start()` has handed over the task, so `adopt` remembers an early
/// cancellation and applies it immediately. Without that, an expiration during launch left the loop
/// running with no handle to stop it.
///
/// State lives in an `OSAllocatedUnfairLock`, so this is `Sendable` with no `@unchecked` escape:
/// `cancel()` may be called from a `BGTaskScheduler` expiration handler on any thread while
/// `adopt` is called on the main actor. The stored `Task` is cancelled outside the lock, since
/// `Task.cancel()` can run cancellation handlers synchronously and would re-enter.
final class BackgroundWorkCancellation: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var wasCancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func adopt(_ task: Task<Void, Never>) {
        let cancelImmediately = state.withLock { current -> Bool in
            if current.wasCancelled { return true }
            current.task = task
            return false
        }
        if cancelImmediately { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { current -> Task<Void, Never>? in
            current.wasCancelled = true
            return current.task
        }
        task?.cancel()
    }

    var isCancelled: Bool {
        state.withLock { $0.wasCancelled }
    }
}

/// A lock-backed boolean whose `claim()` succeeds exactly once.
///
/// Used instead of a main-actor `var` so any reader — including a nonisolated context — sees a
/// coherent value without an `@unchecked` escape. The single-claim property is what lets the
/// background handlers guarantee a task is completed even when the main-actor runner never gets to
/// start (see `BackgroundTaskOwnership`).
final class BackgroundWorkCompletionFlag: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)

    var isSet: Bool { value.withLock { $0 } }

    func set() { value.withLock { $0 = true } }

    /// Returns `true` for exactly one caller; every other caller gets `false`.
    @discardableResult
    func claim() -> Bool {
        value.withLock { claimed in
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Guarantees one party takes responsibility for completing a `BGTask`.
///
/// Two handlers hand the task to a `Task { @MainActor in … }` so the work starts on the main actor.
/// That hop can be lost — the app can be suspended or terminated in the window between the
/// `BGTaskScheduler` launch handler returning and the main-actor task running — and then nobody
/// ever calls `setTaskCompleted`, leaving the app's background budget held open until the system
/// kills it.
///
/// This resolves it with one claim: whichever of the runner or the expiration handler claims
/// ownership first is responsible. If expiration arrives and nobody has claimed, the runner will
/// never run, so expiration completes the task itself. If the runner claimed first, it will reach
/// a `finish` on every path.
///
/// ## Why this is not declared `Sendable`
///
/// It holds a `BackgroundTaskCompletionGate`, which holds the `BGTask` through its completion
/// closure and is therefore not `Sendable` itself. Conforming here would need `@unchecked` — a new
/// escape in the tracked baseline, which this branch must not add. The sharing is safe because the
/// only mutable state is the atomically claimed flag in `BackgroundWorkCompletionFlag`; the gate is
/// lock-protected. That is the same reasoning recorded for the gate in
/// `Tools/Development/concurrency-audit.json`, and the conformance belongs with the Swift 6 migration, not here.
final class BackgroundTaskOwnership {
    private let claimed = BackgroundWorkCompletionFlag()
    private let gate: BackgroundTaskCompletionGate

    init(gate: BackgroundTaskCompletionGate) {
        self.gate = gate
    }

    /// Called by the runner immediately before it starts its loop.
    func runnerDidStart() {
        claimed.set()
    }

    /// Called from the expiration handler, which is neither async nor main-actor.
    func expired() {
        // Nobody claimed ownership, so no runner will ever close the gate. Do it here.
        if claimed.claim() {
            gate.finish(success: false, source: .expiration)
        }
    }
}

/// Runs one background download task to a single, well-defined conclusion.
///
/// Replaces the previous "expiration handler completes, then a worker on a global queue completes
/// again" arrangement:
///
/// * `BackgroundTaskCompletionGate` guarantees exactly one `setTaskCompleted(success:)`.
/// * Expiration cancels the loop and cannot overwrite a result that already landed; a late worker
///   cannot overwrite expiration either.
/// * Polling uses `Task.sleep`, which suspends instead of occupying a thread, and is cancellable.
/// * All download state is read on the main actor as copied values.
@MainActor
final class BackgroundDownloadRunner {
    private let gate: BackgroundTaskCompletionGate
    private let monitor: BackgroundDownloadMonitoring
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let pauseOnCancellation: Bool
    private let onProgress: (BackgroundDownloadWork) -> Void
    private let ownership: BackgroundTaskOwnership?

    /// Supplied by the caller so the expiration handler can be wired synchronously, before this
    /// main-actor runner exists. An expiration that lands in that window would otherwise have no
    /// handler to reach.
    let cancellation: BackgroundWorkCancellation

    private var didStart = false
    private let didFinish = BackgroundWorkCompletionFlag()

    /// - Parameters:
    ///   - timeout: wall-clock budget. The original processing handler used 4 minutes.
    ///   - pollInterval: sleep between samples. The original used a blocking 5-second sleep.
    ///   - pauseOnCancellation: whether expiration pauses downloads. `BGProcessingTask` does,
    ///     because losing background time means the system suspends the transfer anyway and it
    ///     should be left resumable. `BGContinuedProcessingTask` does not — keeping the download
    ///     alive is its entire purpose, and pausing would be a behaviour regression.
    ///   - onProgress: mirrors the sample onto `BGTask.progress`, which the system requires for
    ///     continued-processing tasks. Cosmetic, and deliberately separate from completion.
    init(
        gate: BackgroundTaskCompletionGate,
        monitor: BackgroundDownloadMonitoring,
        cancellation: BackgroundWorkCancellation,
        timeout: TimeInterval = 4 * 60,
        pollInterval: TimeInterval = 5,
        pauseOnCancellation: Bool = false,
        ownership: BackgroundTaskOwnership? = nil,
        onProgress: @escaping (BackgroundDownloadWork) -> Void = { _ in }
    ) {
        self.gate = gate
        self.monitor = monitor
        self.cancellation = cancellation
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.pauseOnCancellation = pauseOnCancellation
        self.ownership = ownership
        self.onProgress = onProgress
    }

    /// Starts monitoring. Calling it twice does not stack monitors: the first monitor owns the one
    /// result, and the gate would drop a duplicate anyway.
    func start() {
        guard !didStart else { return }
        didStart = true
        // Written as two statements rather than `await self?.run()`: an optional-chained call as
        // the sole expression makes the closure's inferred result `Void?`, which does not match the
        // `Task<Void, Never>` the cancellation handle stores.
        let monitoring = Task { @MainActor [weak self] in
            // `[weak self]` because the handler must not be kept alive by its own monitor. The
            // strong reference is taken here, the moment the loop starts, so `run()` always
            // finishes and every path through it closes the gate.
            guard let self else { return }
            // Claimed before the first suspension point inside `run()`: from here on every path
            // through the loop reaches a `finish`, so expiration must not complete the task.
            self.ownership?.runnerDidStart()
            await self.run()
        }
        cancellation.adopt(monitoring)
    }

    func run() async {
        monitor.resumeAll()

        // ContinuousClock is monotonic, unlike Date(): it cannot be pulled sideways by a clock
        // adjustment or a long sleep, so the timeout budget measures real elapsed time.
        let clock = ContinuousClock()
        let started = clock.now

        while true {
            if cancellation.isCancelled {
                finishCancelled()
                return
            }

            let work = monitor.currentWork()
            onProgress(work)

            let elapsed = (clock.now - started).timeInterval
            switch BackgroundDownloadMonitorPolicy.decide(work: work, elapsed: elapsed, timeout: timeout) {
            case .finished:
                didFinish.set()
                gate.finish(success: true, source: .worker)
                return
            case .timedOut(let workRemaining):
                // Truthful outcome: a timeout with work left did not succeed, so the system is
                // free to hand the task back later.
                didFinish.set()
                gate.finish(success: !workRemaining, source: .worker)
                return
            case .keepMonitoring:
                do {
                    try await sleepForBackgroundPolling(pollInterval)
                } catch {
                    // Cancellation is the only thing that throws here.
                    finishCancelled()
                    return
                }
            }
        }
    }

    /// True once an outcome has been decided. The gate is still the authority on whether it
    /// actually closed.
    ///
    /// Deliberately *not* reached from a `deinit`. `AppInstaller.deinit` sets the safe precedent:
    /// only stored task handles are cancelled there, never main-actor state. Completing the gate
    /// from `deinit` would need either an isolated read or a new `@unchecked` escape, so the
    /// protection is structural instead: `run()` has no early return that skips a `finish`, and
    /// every cancellation path funnels through `finishCancelled()`.
    var hasFinished: Bool { didFinish.isSet }

    /// Expiration path: optionally stop the downloads the task was keeping alive, then close the
    /// gate. Both steps are idempotent, and `finish` cannot override a result that already landed.
    private func finishCancelled() {
        didFinish.set()
        if pauseOnCancellation {
            monitor.pauseAll()
        }
        gate.expire()
    }
}
