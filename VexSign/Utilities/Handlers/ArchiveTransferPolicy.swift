// Adapted from KorSign's ArchiveHandler.archive(compressForTransfer:).
// Original file notice: Created by samara on 22.04.2025; KorSign contributors.
// GNU GPL version 3; see LICENSE and docs/THIRD_PARTY_ADAPTATIONS.md.

import Zip

/// Pairing upload is often transport-bound. Use fast compression when a transfer
/// would otherwise send an uncompressed IPA, without changing export preferences.
enum ArchiveTransferPolicy {
    static func compression(storedIndex: Int, compressForTransfer: Bool) -> ZipCompression {
        let choices = ZipCompression.allCases
        let selected = choices.indices.contains(storedIndex) ? choices[storedIndex] : .DefaultCompression
        return compressForTransfer && selected == .NoCompression ? .BestSpeed : selected
    }
}
