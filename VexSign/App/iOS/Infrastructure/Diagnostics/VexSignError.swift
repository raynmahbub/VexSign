import Foundation
import OSLog

/// Unified error type for VexSign with structured metadata for diagnostics.
struct VexSignError: LocalizedError, Sendable {
    enum Code: String, Sendable {
        // Storage
        case storeUnavailable
        case storeCorrupt
        case storeMigrationFailed
        case entityNotFound
        
        // Certificate/Identity
        case certificateImportFailed
        case certificateNotFound
        case certificateExpired
        case certificateRevoked
        case certificatePasswordInvalid
        case keychainOperationFailed
        case provisioningProfileInvalid
        
        // Signing
        case signingFailed
        case signingCancelled
        case signingBusy
        case preflightFailed
        case entitlementsMismatch
        case bundleIdMismatch
        case teamIdMismatch
        
        // Installation
        case installationFailed
        case installationCancelled
        case installationUnconfirmed
        case installationNeverStarted
        case httpsTrustRequired
        case pairingFileInvalid
        case pairingFileMissing
        case deviceUnreachable
        
        // Download/Import
        case downloadFailed
        case downloadCancelled
        case downloadPaused
        case downloadSizeExceeded
        case downloadIntegrityFailed
        case importFailed
        case archiveInvalid
        case archiveExtractionFailed
        case archiveSizeExceeded
        case archiveUnsafePath
        case diskSpaceInsufficient
        
        // Repository/Source
        case sourceUnreachable
        case sourceInvalidFormat
        case sourceAuthFailed
        case sourceRateLimited
        case appNotFoundInSource
        
        // Tweak/Injection
        case tweakNotFound
        case tweakInjectionFailed
        case tweakDependencyMissing
        case elleKitNotFound
        
        // Backup/Restore
        case backupCreationFailed
        case backupRestoreFailed
        case backupCorrupt
        case backupPasswordInvalid
        
        // Network/Connectivity
        case networkUnavailable
        case networkTimeout
        case serverError
        case invalidResponse
        
        // Permissions/Privacy
        case permissionDenied
        case privacyServicesDenied
        
        // Generic
        case invalidInput
        case operationCancelled
        case operationTimeout
        case unknown
    }
    
    let code: Code
    let message: String
    let underlyingError: (any Error)?
    let context: [String: String]
    let file: String
    let function: String
    let line: Int
    
    init(
        _ code: Code,
        message: String,
        underlyingError: (any Error)? = nil,
        context: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        self.code = code
        self.message = message
        self.underlyingError = underlyingError
        self.context = context
        self.file = file
        self.function = function
        self.line = line
    }
    
    var errorDescription: String? {
        var parts = [message]
        
        if let underlying = underlyingError {
            parts.append("Underlying: \(underlying.localizedDescription)")
        }
        
        if !context.isEmpty {
            let ctx = context.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            parts.append("Context: [\(ctx)]")
        }
        
        #if DEBUG
        parts.append("Ref: \(file):\(function):\(line)")
        #endif
        
        return parts.joined(separator: "\n")
    }
    
    var debugDescription: String {
        "VexSignError(\(code.rawValue)): \(message)"
    }
    
    // MARK: - Convenience constructors
    
    static func store(_ message: String, underlying: (any Error)? = nil, context: [String: String] = [:]) -> VexSignError {
        VexSignError(.storeUnavailable, message: message, underlyingError: underlying, context: context)
    }
    
    static func certificate(_ message: String, code: Code = .certificateImportFailed, underlying: (any Error)? = nil, context: [String: String] = [:]) -> VexSignError {
        VexSignError(code, message: message, underlyingError: underlying, context: context)
    }
    
    static func signing(_ message: String, code: Code = .signingFailed, underlying: (any Error)? = nil, context: [String: String] = [:]) -> VexSignError {
        VexSignError(code, message: message, underlyingError: underlying, context: context)
    }
    
    static func installation(_ message: String, code: Code = .installationFailed, underlying: (any Error)? = nil, context: [String: String] = [:]) -> VexSignError {
        VexSignError(code, message: message, underlyingError: underlying, context: context)
    }
    
    static func download(_ message: String, code: Code = .downloadFailed, underlying: (any Error)? = nil, context: [String: String] = [:]) -> VexSignError {
        VexSignError(code, message: message, underlyingError: underlying, context: context)
    }
    
    static func importIPA(_ message: String, code: Code = .importFailed, underlying: (any Error)? = nil, context: [String: String] = [:]) -> VexSignError {
        VexSignError(code, message: message, underlyingError: underlying, context: context)
    }
    
    static func source(_ message: String, code: Code = .sourceUnreachable, underlying: (any Error)? = nil, context: [String: String] = [:]) -> VexSignError {
        VexSignError(code, message: message, underlyingError: underlying, context: context)
    }
    
    static func tweak(_ message: String, code: Code = .tweakInjectionFailed, underlying: (any Error)? = nil, context: [String: String] = [:]) -> VexSignError {
        VexSignError(code, message: message, underlyingError: underlying, context: context)
    }
    
    static func backup(_ message: String, code: Code = .backupCreationFailed, underlying: (any Error)? = nil, context: [String: String] = [:]) -> VexSignError {
        VexSignError(code, message: message, underlyingError: underlying, context: context)
    }
    
    static func network(_ message: String, code: Code = .networkUnavailable, underlying: (any Error)? = nil, context: [String: String] = [:]) -> VexSignError {
        VexSignError(code, message: message, underlyingError: underlying, context: context)
    }
    
    static func permission(_ message: String, underlying: (any Error)? = nil) -> VexSignError {
        VexSignError(.permissionDenied, message: message, underlyingError: underlying)
    }
    
    static func invalidInput(_ message: String, context: [String: String] = [:]) -> VexSignError {
        VexSignError(.invalidInput, message: message, context: context)
    }
    
    static func unknown(_ message: String, underlying: (any Error)? = nil) -> VexSignError {
        VexSignError(.unknown, message: message, underlyingError: underlying)
    }
}

// MARK: - Logging helper

extension VexSignError {
    func log(category: String = "error", level: OSLogType = .error) {
        let logMessage = "VexSignError[\(code.rawValue)]: \(message)"
        Logger.misc.log(level: level, "\(logMessage, privacy: .public)")
        if let underlying = underlyingError {
            Logger.misc.log(level: level, "  Underlying: \(underlying.localizedDescription, privacy: .public)")
        }
        if !context.isEmpty {
            Logger.misc.log(level: level, "  Context: \(context, privacy: .public)")
        }
        #if DEBUG
        Logger.misc.log(level: level, "  Ref: \(file):\(function):\(line)")
        #endif
    }
}

// MARK: - Bridging from existing error types

extension VexSignError {
    init(from error: Error, defaultCode: Code = .unknown, context: [String: String] = [:]) {
        if let vexError = error as? VexSignError {
            self = vexError
        } else if let nsError = error as NSError? {
            // Map common NSError domains/codes
            let code: Code
            switch nsError.domain {
            case NSURLErrorDomain:
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                    code = .networkUnavailable
                case NSURLErrorTimedOut:
                    code = .networkTimeout
                case NSURLErrorCancelled:
                    code = .operationCancelled
                default:
                    code = .networkUnavailable
                }
            case NSCocoaErrorDomain:
                switch nsError.code {
                case NSFileReadNoSuchFileError:
                    code = .entityNotFound
                case NSFileWriteOutOfSpaceError:
                    code = .diskSpaceInsufficient
                case NSFileWriteFileExistsError:
                    code = .invalidInput
                default:
                    code = .unknown
                }
            case "VexSign.Download":
                code = .downloadFailed
            case "VexSign.Signing":
                code = .signingFailed
            case "VexSign.Installation":
                code = .installationFailed
            default:
                code = defaultCode
            }
            self.init(code, message: nsError.localizedDescription, underlyingError: error, context: context)
        } else {
            self.init(defaultCode, message: error.localizedDescription, underlyingError: error, context: context)
        }
    }
}