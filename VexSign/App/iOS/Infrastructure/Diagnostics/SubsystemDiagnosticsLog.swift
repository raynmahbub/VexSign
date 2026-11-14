import Foundation

/// Structured diagnostic logging façade that routes redacted events through `FileLogger`
/// while preserving consistent architectural subsystem categories.
enum SubsystemDiagnosticsLog {
    enum Subsystem: String, Sendable {
        case architecture
        case routing
        case network
        case security
        case signing
        case install
        case storage
        case certificates
    }

    static func info(_ message: String, subsystem: Subsystem) {
        FileLogger.log(message, category: subsystem.rawValue)
    }

    static func warn(_ message: String, subsystem: Subsystem) {
        FileLogger.warn(message, category: subsystem.rawValue)
    }

    static func error(_ error: Error, subsystem: Subsystem, context: [String: String] = [:]) {
        let classified = ErrorBoundary.classify(error, context: context)
        FileLogger.error("[\(classified.code.rawValue)] \(classified.message)", category: subsystem.rawValue)
    }

    static func errorMessage(_ message: String, subsystem: Subsystem) {
        FileLogger.error(message, category: subsystem.rawValue)
    }
}
