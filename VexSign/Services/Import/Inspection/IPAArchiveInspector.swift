// Bounded summary of a validated IPA archive. The security decision stays in
// ArchiveSafetyValidator; this only records what the archive actually carried
// so the library can describe it without reopening the file later.

import Foundation
import ZIPFoundation

enum IPAArchiveInspector {
    static func summarize(
        _ source: URL,
        checkpoint: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> AppBundleInspection.ArchiveSummary {
        // No destination: the shared validator checks structure, paths, counts,
        // sizes and compression ratios but does not repeat a storage preflight.
        try ArchiveSafetyValidator.validate(source, destination: nil, checkpoint: checkpoint)
        let archive = try Archive(url: source, accessMode: .read)
        var entryCount = 0
        var total: UInt64 = 0
        var largestPath: String?
        var largestBytes: UInt64 = 0
        var methods: Set<String> = []
        var payloadDirectories = Set<String>()
        var hasPayload = false

        for entry in archive {
            try checkpoint()
            entryCount += 1
            total += entry.uncompressedSize
            if entry.uncompressedSize > largestBytes {
                largestBytes = entry.uncompressedSize
                largestPath = entry.path
            }
            // ZIPFoundation exposes only isCompressed on Entry; the codec name is not public.
            methods.insert(entry.isCompressed ? "compressed" : "stored")
            let components = ArchiveSafetyValidator.normalizedComponents(entry.path).map(String.init)
            if components.first == "Payload" {
                hasPayload = true
                if components.count >= 2, components[1].lowercased().hasSuffix(".app") {
                    payloadDirectories.insert(components[1])
                }
            }
        }
        return .init(entryCount: entryCount,
                     totalExpandedBytes: total,
                     largestEntryPath: largestPath,
                     largestEntryBytes: largestBytes,
                     compressionMethods: methods.sorted(),
                     hasPayloadDirectory: hasPayload,
                     payloadAppBundleCount: payloadDirectories.count)
    }
}
