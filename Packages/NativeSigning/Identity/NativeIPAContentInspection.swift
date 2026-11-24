import Foundation
import os

public enum NativeIPAInspectionError: Error, Equatable, Sendable {
    case busy, invalidArchive, unsupportedContent, resourceLimit, decompressionFailed, checksumMismatch
}

/// Read-only local inspection receipt, not publisher/certificate trust or signing
/// permission. Does not export file contents, identity material or private paths.
public struct NativeIPAContentInspection: Sendable {
    private static let active = OSAllocatedUnfairLock(initialState: false)
    public let archiveSHA256: String
    public let bundleIdentifier: String
    public let entryCount: Int
    public let expandedBytes: Int
    private init(content: NativeVerifiedIPAContent, bundleIdentifier: String) {
        archiveSHA256 = content.archiveSHA256; self.bundleIdentifier = bundleIdentifier
        entryCount = content.entrySHA256.count; expandedBytes = content.expandedBytes
    }

    /// Runs bounded archive/namespace/all-entry checksum/content inspection off
    /// the caller's actor. Cancelled callers await actual worker retirement;
    /// no orphaned work, account lease, Apple request or filesystem extraction.
    public static func inspect(archive: Data, bundleIdentifier: String) async throws -> Self {
        try Task.checkCancellation()
        try active.withLock {
            guard !$0 else { throw NativeIPAInspectionError.busy }
            $0 = true
        }
        // One memory-intensive public inspection at a time, including cancelled
        // but not-yet-retired workers. Internal callers must serialize likewise.
        defer { active.withLock { $0 = false } }
        let worker = Task.detached(priority: .userInitiated) {
            try NativeIPAContentVerifier.verify(archive, bundleIdentifier: bundleIdentifier)
        }
        do {
            let content = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            return Self(content: content, bundleIdentifier: bundleIdentifier)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            switch error {
            case NativeIPAArchiveError.resourceLimit: throw NativeIPAInspectionError.resourceLimit
            case NativeIPAArchiveError.unsupportedFormat, NativeIPAArchiveError.unsupportedLayout:
                throw NativeIPAInspectionError.unsupportedContent
            case NativeIPAEntryDecoder.Failure.checksumMismatch: throw NativeIPAInspectionError.checksumMismatch
            case NativeIPAEntryDecoder.Failure.decompressionFailed: throw NativeIPAInspectionError.decompressionFailed
            case is NativeSigningAcceptanceError: throw NativeIPAInspectionError.unsupportedContent
            default: throw NativeIPAInspectionError.invalidArchive
            }
        }
    }
}
