import Foundation

/// Centralized boundary for translating domain, network, security, and OS errors into
/// structured `VexSignError` instances with redacted diagnostics and safe user messages.
enum ErrorBoundary {
    static func classify(
        _ error: Error,
        defaultCode: VexSignError.Code = .unknown,
        context: [String: String] = [:]
    ) -> VexSignError {
        if let existing = error as? VexSignError {
            return existing
        }

        if error is CancellationError {
            return VexSignError(.operationCancelled, message: error.localizedDescription, underlyingError: error, context: context)
        }

        if let domain = error as? ArchitectureDomainError {
            return classifyDomainError(domain, context: context)
        }

        if let policy = error as? PackageDownloadURLPolicy.Failure {
            switch policy {
            case .packageTooLarge:
                return VexSignError(.downloadSizeExceeded, message: policy.localizedDescription, underlyingError: policy, context: context)
            case .unsupportedURL, .insecureTransport, .redirectDowngrade:
                return VexSignError(.downloadFailed, message: policy.localizedDescription, underlyingError: policy, context: context)
            }
        }

        if let routing = error as? InstallationRoutingError {
            return VexSignError(.installationFailed, message: routing.localizedDescription, underlyingError: routing, context: context)
        }

        if let crypto = error as? BackupCrypto.Failure {
            let code: VexSignError.Code = crypto == .wrongPassword ? .backupPasswordInvalid : .backupCorrupt
            return VexSignError(code, message: crypto.localizedDescription, underlyingError: crypto, context: context)
        }

        return VexSignError(from: error, defaultCode: defaultCode, context: context)
    }

    static func userMessage(for error: Error) -> String {
        let message = classify(error).message
        return LogRedaction.redact(message)
    }

    private static func classifyDomainError(
        _ domain: ArchitectureDomainError,
        context: [String: String]
    ) -> VexSignError {
        switch domain {
        case .invalidURL, .unsupportedScheme, .insecureTransport, .redirectBlocked:
            return VexSignError(.downloadFailed, message: domain.localizedDescription, underlyingError: domain, context: context)
        case .httpError(let status):
            var enriched = context
            enriched["httpStatus"] = "\(status)"
            return VexSignError(.serverError, message: domain.localizedDescription, underlyingError: domain, context: enriched)
        case .transferSizeExceeded:
            return VexSignError(.downloadSizeExceeded, message: domain.localizedDescription, underlyingError: domain, context: context)
        case .emptyDownloadPayload:
            return VexSignError(.invalidResponse, message: domain.localizedDescription, underlyingError: domain, context: context)
        case .unsafeCallbackTemplate, .missingCertificateMaterial:
            return VexSignError(.certificateImportFailed, message: domain.localizedDescription, underlyingError: domain, context: context)
        case .duplicateOrBusyOperation:
            return VexSignError(.signingBusy, message: domain.localizedDescription, underlyingError: domain, context: context)
        case .importFailed:
            return VexSignError(.importFailed, message: domain.localizedDescription, underlyingError: domain, context: context)
        case .resetFailed:
            return VexSignError(.storeUnavailable, message: domain.localizedDescription, underlyingError: domain, context: context)
        }
    }
}
