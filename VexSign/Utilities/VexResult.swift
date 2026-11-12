import Foundation

/// Result type alias for VexSign operations.
typealias VexResult<T> = Result<T, VexSignError>

extension Result where Failure == VexSignError {
    /// Maps the success value to a new value, or passes through the error.
    func map<U>(_ transform: (Success) throws -> U) -> VexResult<U> {
        switch self {
        case .success(let value):
            do {
                return .success(try transform(value))
            } catch let error as VexSignError {
                return .failure(error)
            } catch {
                return .failure(VexSignError(from: error))
            }
        case .failure(let error):
            return .failure(error)
        }
    }
    
    /// Maps the success value to a new Result, or passes through the error.
    func flatMap<U>(_ transform: (Success) throws -> VexResult<U>) -> VexResult<U> {
        switch self {
        case .success(let value):
            do {
                return try transform(value)
            } catch let error as VexSignError {
                return .failure(error)
            } catch {
                return .failure(VexSignError(from: error))
            }
        case .failure(let error):
            return .failure(error)
        }
    }
    
    /// Returns the success value or throws the error.
    func get() throws -> Success {
        switch self {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
    
    /// Returns the error if failed, nil if succeeded.
    var error: VexSignError? {
        if case .failure(let error) = self { return error }
        return nil
    }
    
    /// Returns the value if succeeded, nil if failed.
    var value: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
    
    /// Executes a closure if the result is a success.
    @discardableResult
    func onSuccess(_ body: (Success) -> Void) -> Self {
        if case .success(let value) = self { body(value) }
        return self
    }
    
    /// Executes a closure if the result is a failure.
    @discardableResult
    func onFailure(_ body: (VexSignError) -> Void) -> Self {
        if case .failure(let error) = self { body(error) }
        return self
    }
    
    /// Logs the error if failed.
    func logIfFailed(category: String = "error") -> Self {
        if case .failure(let error) = self {
            error.log(category: category)
        }
        return self
    }
}

// MARK: - Async helpers

extension VexResult {
    /// Creates a VexResult from an async throwing operation.
    static func catching(
        _ operation: @escaping () async throws -> Success,
        defaultCode: VexSignError.Code = .unknown,
        context: [String: String] = [:]
    ) async -> VexResult<Success> {
        do {
            let value = try await operation()
            return .success(value)
        } catch {
            return .failure(VexSignError(from: error, defaultCode: defaultCode, context: context))
        }
    }
    
    /// Creates a VexResult from a sync throwing operation.
    static func catching(
        _ operation: @escaping () throws -> Success,
        defaultCode: VexSignError.Code = .unknown,
        context: [String: String] = [:]
    ) -> VexResult<Success> {
        do {
            let value = try operation()
            return .success(value)
        } catch {
            return .failure(VexSignError(from: error, defaultCode: defaultCode, context: context))
        }
    }
}

// MARK: - Bridging from completion handlers

extension VexResult {
    /// Converts a completion-handler-based async operation to a VexResult.
    static func fromCompletion<T>(
        defaultCode: VexSignError.Code = .unknown,
        context: [String: String] = [:],
        _ operation: @escaping (@escaping (VexResult<T>) -> Void) -> Void
    ) async -> VexResult<T> {
        await withCheckedContinuation { continuation in
            operation { result in
                continuation.resume(returning: result)
            }
        }
    }
}