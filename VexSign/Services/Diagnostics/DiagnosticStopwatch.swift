//
//  DiagnosticStopwatch.swift
//  VexSign
//
//  Real interval measurement: an OSSignposter interval for Instruments and a
//  ContinuousClock duration for an exportable event. No simulated timings and
//  no thresholds — every number here is observed on the device that ran the work.
//

import Foundation
import OSLog

struct DiagnosticStopwatch {
    private let signposter: OSSignposter
    private let signpostID: OSSignpostID
    private let interval: OSSignpostIntervalState
    private let name: StaticString
    private let category: DiagnosticCategory
    private let operationID: String?
    private let startedAt: ContinuousClock.Instant

    init(_ name: StaticString, category: DiagnosticCategory, operationID: String? = nil) {
        let logger = Logger(subsystem: category.subsystem, category: category.rawValue)
        self.signposter = OSSignposter(logger: logger)
        self.name = name
        self.category = category
        self.operationID = operationID
        self.signpostID = signposter.makeSignpostID()
        self.interval = signposter.beginInterval(name, id: signpostID)
        self.startedAt = ContinuousClock.now
    }

    /// Ends the Instruments interval exactly once and returns the observed duration.
    @discardableResult
    func finish() -> TimeInterval {
        let duration = startedAt.duration(to: ContinuousClock.now)
        signposter.endInterval(name, interval)
        return Self.milliseconds(duration)
    }

    func event(
        code: String = DiagnosticEventCode.performanceMeasurement,
        severity: DiagnosticSeverity = .info,
        elapsedMilliseconds: TimeInterval,
        detail: String? = nil
    ) -> DiagnosticEvent {
        .make(
            code: code,
            severity: severity,
            category: category,
            operationID: operationID,
            userMessage: "Measured \(name) in \(String(format: "%.1f", elapsedMilliseconds)) ms.",
            developerDetail: detail,
            metadata: [
                "interval": String(describing: name),
                "elapsedMs": String(format: "%.1f", elapsedMilliseconds)
            ]
        )
    }

    private static func milliseconds(_ duration: Duration) -> TimeInterval {
        let seconds = Double(duration.components.seconds)
        let attoseconds = Double(duration.components.attoseconds) / 1_000_000_000_000_000
        return (seconds + attoseconds) * 1000
    }
}
