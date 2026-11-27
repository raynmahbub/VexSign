// Persists inspection evidence beside a library app record, never inside the
// app bundle. Writing into the bundle would modify the signature the importer
// is describing.

import Foundation

enum ImportInspectionStore {
    enum StoreError: LocalizedError {
        case tooLarge
        case unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "The inspection report exceeds its storage limit."
            case .unreadable:
                return "The stored inspection report could not be read."
            }
        }
    }

    static let schema = 1
    private static let maximumReportBytes = 4 * 1024 * 1024
    private static let directoryName = "Inspection"
    private static let reportName = "app-inspection.json"
    private static let originalInfoName = "Original-Info.plist"

    static func directory(for appDirectory: URL) -> URL {
        appDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    @discardableResult
    static func write(
        _ result: AppBundleInspectionResult,
        to appDirectory: URL
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let report = try encoder.encode(result.report)
        guard report.count <= maximumReportBytes,
              (result.originalInfoPlist?.count ?? 0) <= maximumReportBytes else {
            throw StoreError.tooLarge
        }
        let directory = directory(for: appDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try report.write(to: directory.appendingPathComponent(reportName), options: .atomic)
        if let plist = result.originalInfoPlist {
            try plist.write(to: directory.appendingPathComponent(originalInfoName), options: .atomic)
        }
        return directory
    }

    static func read(from appDirectory: URL) -> AppBundleInspection? {
        let url = directory(for: appDirectory).appendingPathComponent(reportName)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), // try? ok: a missing or unreadable sidecar has no report
              data.count <= maximumReportBytes else { return nil }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(AppBundleInspection.self, from: data), // try? ok: a malformed sidecar is treated as absent
              report.schema == schema else { return nil }
        return report
    }

    static func originalInfoPlist(from appDirectory: URL) -> Data? {
        let url = directory(for: appDirectory).appendingPathComponent(originalInfoName)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil } // try? ok: original metadata is optional once inspected
        return data.count <= maximumReportBytes ? data : nil
    }

    static func remove(from appDirectory: URL) {
        try? FileManager.default.removeItem(at: directory(for: appDirectory)) // try? ok: sidecar cleanup is best-effort
    }
}
