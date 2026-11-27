//
//  MetricKitDiagnosticsService.swift
//  VexSign
//
//  Receives system-generated diagnostics from MetricKit and turns them into
//  safe, bounded structured events. Call stacks, binary images, addresses and
//  the raw payload JSON are deliberately never read, stored or exported.
//
//  Delivery is controlled by iOS: crash and hang reports can arrive later or not
//  at all, daily metrics arrive at most once per day, and a simulator receives
//  no real device reports. The UI must say so rather than implying live capture.
//  MXMetricManagerSubscriber is the API for the app's iOS 17 deployment target.
//  No third-party crash SDK or cloud uploader is added.
//

#if canImport(MetricKit)
import Foundation
import MetricKit

final class MetricKitDiagnosticsService: NSObject, MXMetricManagerSubscriber {
    private let recorder: DiagnosticRecorder

    init(recorder: DiagnosticRecorder = .fileRecorder) {
        self.recorder = recorder
        super.init()
    }

    /// Register once from the app delegate. Registered callbacks are retained by
    /// MetricKit; `stop()` removes them when a host app needs to tear down.
    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let window = Self.windowMetadata(payload)
            for diagnostic in payload.crashDiagnostics ?? [] {
                // Mach signal and exception type are numeric and useful; the
                // exception reason, VM region info and call stack are not read.
                var metadata = window
                if let signal = diagnostic.signal { metadata["signal"] = signal.stringValue }
                if let exception = diagnostic.exceptionType { metadata["exceptionType"] = exception.stringValue }
                emit(Self.event(
                    code: DiagnosticEventCode.metricKitCrash,
                    message: "iOS reported an app crash.",
                    detail: "MetricKit crash diagnostic; no stack frames were read.",
                    severity: .error,
                    metadata: metadata
                ))
            }
            for diagnostic in payload.hangDiagnostics ?? [] {
                var metadata = window
                metadata["hangMs"] = Self.milliseconds(diagnostic.hangDuration.converted(to: .seconds).value)
                emit(Self.event(
                    code: DiagnosticEventCode.metricKitHang,
                    message: "iOS reported an unresponsive interval.",
                    detail: "MetricKit hang diagnostic duration recorded in milliseconds.",
                    metadata: metadata
                ))
            }
            for diagnostic in payload.cpuExceptionDiagnostics ?? [] {
                var metadata = window
                metadata["cpuTimeMs"] = Self.milliseconds(diagnostic.totalCPUTime.converted(to: .seconds).value)
                metadata["sampledTimeMs"] = Self.milliseconds(diagnostic.totalSampledTime.converted(to: .seconds).value)
                emit(Self.event(
                    code: DiagnosticEventCode.metricKitCPU,
                    message: "iOS reported excessive CPU use.",
                    detail: "MetricKit CPU exception; durations recorded in milliseconds.",
                    severity: .error,
                    metadata: metadata
                ))
            }
            if #available(iOS 16.0, *) {
                for diagnostic in payload.appLaunchDiagnostics ?? [] {
                    var metadata = window
                    metadata["launchMs"] = Self.milliseconds(diagnostic.launchDuration.converted(to: .seconds).value)
                    emit(Self.event(
                        code: DiagnosticEventCode.metricKitLaunch,
                        message: "iOS reported an app launch diagnostic.",
                        detail: "MetricKit launch duration recorded in milliseconds.",
                        metadata: metadata
                    ))
                }
            }
            for _ in payload.diskWriteExceptionDiagnostics ?? [] {
                emit(Self.event(
                    code: DiagnosticEventCode.metricKitDisk,
                    message: "iOS reported excessive disk writes.",
                    detail: "MetricKit disk-write exception; no file names were read.",
                    metadata: window
                ))
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Daily performance payloads contain aggregated values, not per-failure
        // evidence. Record only the fact of delivery so a user can tell the
        // framework is active; never serialize the payload itself.
        guard !payloads.isEmpty else { return }
        emit(Self.event(
            code: DiagnosticEventCode.appHealth,
            message: "MetricKit delivered a daily performance report.",
            detail: "Aggregated metrics were not stored in the diagnostic journal.",
            metadata: ["payloadCount": String(payloads.count)]
        ))
    }

    private func emit(_ event: DiagnosticEvent) {
        Task { await recorder.record(event) }
    }

    private static func event(
        code: String,
        message: String,
        detail: String,
        severity: DiagnosticSeverity = .warning,
        metadata: [String: String]
    ) -> DiagnosticEvent {
        .make(
            code: code,
            severity: severity,
            category: .metricKit,
            userMessage: message,
            developerDetail: detail,
            recoverySuggestion: "Use the Troubleshooting Center to correlate system reports with recent operations.",
            metadata: metadata
        )
    }

    private static func windowMetadata(_ payload: MXDiagnosticPayload) -> [String: String] {
        let formatter = ISO8601DateFormatter()
        return [
            "windowStart": formatter.string(from: payload.timeStampBegin),
            "windowEnd": formatter.string(from: payload.timeStampEnd)
        ]
    }

    private static func milliseconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0.0" }
        return String(format: "%.1f", value * 1000)
    }
}
#endif
