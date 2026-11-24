import Foundation
import NimbleExtensions

extension WorkspaceAccessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidReference, .missingRecord, .mismatchedRecord: .localized("App files not found.")
        case .persistenceFailed: .localized("Deletion could not be completed. Your app records were kept; recovery files, if any, are retained.")
        case .invalidOrder: .localized("The library could not be reordered.")
        }
    }
}
