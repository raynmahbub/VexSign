import Foundation
import Combine

/// Stream termination may run off-actor. Only subscription ownership crosses
/// executors; producer callbacks hop to their owner's actor before reading state.
/// Taking and clearing the tokens is serialized; cancellation runs outside the
/// lock so a re-entrant completion cannot deadlock or cancel a new subscription.
final class StreamObservationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions: [AnyCancellable]
    init(_ subscriptions: [AnyCancellable]) { self.subscriptions = subscriptions }
    convenience init(_ subscription: AnyCancellable) { self.init([subscription]) }
    func cancel() {
        lock.lock(); let current = subscriptions; subscriptions = []; lock.unlock()
        current.forEach { $0.cancel() }
    }
    deinit { cancel() }
}
