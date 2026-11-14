import Foundation

enum BundleExecutableAudit {
    enum Problem: String, Sendable { case unreadable, malformed, encrypted, unsupportedDeviceBinary, unknownPlatform }
    struct Finding: Identifiable, Equatable, Sendable {
        let path: String
        let problem: Problem
        var id: String { path + ":" + problem.rawValue }
        var isBlocking: Bool { problem != .unknownPlatform }

    }
    struct Report: Sendable {
        let inspected: Int
        let findings: [Finding]
        var blocking: [Finding] { findings.filter(\.isBlocking) }
    }

}

struct SigningReviewEvidence: Sendable {
    let report: BundleExecutableAudit.Report
    let requiredBytes: Int64
}
