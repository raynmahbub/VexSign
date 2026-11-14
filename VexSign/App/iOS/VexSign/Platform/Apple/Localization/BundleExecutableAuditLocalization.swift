import Foundation
import NimbleExtensions

extension BundleExecutableAudit.Finding {
        var detail: String {
            switch problem {
            case .unreadable: return .localized("The declared executable could not be read safely: %@", arguments: path)
            case .malformed: return .localized("Mach-O slice bounds or load commands are invalid or unsupported: %@", arguments: path)
            case .encrypted: return .localized("An executable slice declares encryption. Re-signing does not decrypt it: %@", arguments: path)
            case .unsupportedDeviceBinary: return .localized("An iOS bundle has no arm64 iOS-device executable slice: %@", arguments: path)
            case .unknownPlatform: return .localized("The executable platform could not be established: %@", arguments: path)
            }
        }
}
