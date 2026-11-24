//
//  TransferAcceptancePolicy.swift
//  VexSign
//
//  The transport half of package acceptance: which HTTP statuses may be treated
//  as success, and the byte ceiling one untrusted package may reach.
//
//  Both halves of the app need this answer — `Networking` while it moves bytes,
//  `Services/Download` while it decides what to do with them — and neither may
//  depend on the other. Keeping the rule here means the two layers ask the same
//  question instead of each carrying its own copy, and that changing the ceiling
//  is a one-line change in one place.
//

import Foundation

enum TransferAcceptancePolicy {
    /// Generous bound shared with archive inspection so one untrusted IPA
    /// cannot consume unbounded temporary storage before its contents are checked.
    static let maximumPackageBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    /// A declared or observed size above the ceiling stops the transfer. An
    /// undeclared size (0) is never a reason to refuse the stream.
    static func transferExceedsPackageLimit(expectedBytes: Int64, receivedBytes: Int64) -> Bool {
        (expectedBytes > 0 && expectedBytes > maximumPackageBytes) || receivedBytes > maximumPackageBytes
    }

    /// Only a 2xx response may be read as a body. A redirect that lands on an
    /// error page is a failure, not a package.
    static func isAcceptableHTTPStatus(_ statusCode: Int) -> Bool {
        (200..<300).contains(statusCode)
    }
}
