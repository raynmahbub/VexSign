import Foundation
import SideSign

public enum SideSignTwoFactorBrokerError: Error, Equatable {
    case challengeAlreadyPending
    case unsupportedChallenge
}

/// Transient operation/challenge-bound handoff. Never persists/logs phone numbers,
/// codes or raw server error text. The UI owns no SDK continuation directly.
public actor SideSignTwoFactorBroker {
    public struct Challenge: Sendable, Equatable {
        public let operation: UUID
        public let id: UUID
        public let request: TwoFactorRequest
        public let isRetry: Bool
    }

    private let operation: UUID
    private var cancelled = false
    private var pending: (Challenge, CheckedContinuation<TwoFactorResponse, Error>)?
    private var observer: AsyncStream<Challenge>.Continuation?

    public init(operation: UUID) { self.operation = operation }

    public func pendingChallenge() -> Challenge? { pending?.0 }

    /// One bounded UI observer. Replacing observation does not cancel the SDK
    /// task; the operation owner must cancel on dismiss/sign-out/timeout.
    public func challengeEvents() -> AsyncStream<Challenge> {
        observer?.finish()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            if cancelled {
                continuation.finish()
            } else {
                observer = continuation
                if let challenge = pending?.0 { continuation.yield(challenge) }
            }
        }
    }

    public func request(_ request: TwoFactorRequest) async throws -> TwoFactorResponse {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard pending == nil else { throw SideSignTwoFactorBrokerError.challengeAlreadyPending }
        let sanitized: TwoFactorRequest
        // The SDK's error strings can contain arbitrary server payloads. Expose
        // only a retry flag, never those strings, to the future UI adapter.
        switch request {
        case .selectDeliveryMethod(let mode, let numbers):
            sanitized = .selectDeliveryMethod(preferredMode: mode, phoneNumbers: numbers)
        case .trustedDevice: sanitized = .trustedDevice(error: nil)
        case .sms(let numbers, let id, _): sanitized = .sms(phoneNumbers: numbers, activeID: id, error: nil)
        case .voice(let numbers, let id, _): sanitized = .voice(phoneNumbers: numbers, activeID: id, error: nil)
        @unknown default: throw SideSignTwoFactorBrokerError.unsupportedChallenge
        }
        let numbers: [TrustedPhoneNumber]
        switch sanitized {
        case .selectDeliveryMethod(_, let values), .sms(let values, _, _), .voice(let values, _, _): numbers = values
        case .trustedDevice: numbers = []
        @unknown default: throw SideSignTwoFactorBrokerError.unsupportedChallenge
        }
        guard numbers.count <= 20, Set(numbers.map(\.id)).count == numbers.count,
              numbers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 && $0.number.utf8.count <= 256 }) else {
            throw SideSignTwoFactorBrokerError.unsupportedChallenge
        }
        let challenge = Challenge(operation: operation, id: UUID(), request: sanitized, isRetry: request.error != nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if pending != nil {
                    continuation.resume(throwing: SideSignTwoFactorBrokerError.challengeAlreadyPending)
                } else {
                    pending = (challenge, continuation)
                    observer?.yield(challenge)
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    /// Stale/duplicate replies or invalid delivery/code choices do not consume the
    /// pending continuation. Codes are ASCII six digits, not Unicode numerals.
    @discardableResult
    public func submit(_ response: TwoFactorResponse, operation: UUID, challengeID: UUID) -> Bool {
        guard !cancelled, let (challenge, continuation) = pending,
              operation == self.operation, challenge.id == challengeID,
              valid(response, for: challenge.request) else { return false }
        pending = nil
        if case .cancel = response {
            cancelled = true
            observer?.finish()
            observer = nil
        }
        continuation.resume(returning: response)
        return true
    }

    public func cancel() {
        cancelled = true
        let continuation = pending?.1
        pending = nil
        continuation?.resume(throwing: CancellationError())
        observer?.finish()
        observer = nil
    }

    private func valid(_ response: TwoFactorResponse, for request: TwoFactorRequest) -> Bool {
        let numbers: [TrustedPhoneNumber]
        let acceptsCode: Bool
        switch request {
        case .selectDeliveryMethod(_, let values): numbers = values; acceptsCode = false
        case .trustedDevice: numbers = []; acceptsCode = true
        case .sms(let values, _, _), .voice(let values, _, _): numbers = values; acceptsCode = true
        @unknown default: return false
        }
        switch response {
        case .cancel, .requestTrustedDevice: return true
        case .requestSMS(let id), .requestVoice(let id):
            return numbers.contains { $0.id == id }
        case .verificationCode(let code):
            return acceptsCode && code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
        @unknown default: return false
        }
    }
}
