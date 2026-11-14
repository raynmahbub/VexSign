import Foundation
import NimbleExtensions

extension MachOInspector.Issue {
        var message: String {
            switch self {
            case .notMachO:
                return .localized("This file is not a Mach-O binary.")
            case .truncatedHeader:
                return .localized("The binary header is truncated.")
            case .malformedLoadCommands(let index):
                return .localized("Load command %lld is malformed, so the rest of the command list cannot be read.", arguments: index)
            case .invalidStringOffset(let index):
                return .localized("Load command %lld points at a name outside itself.", arguments: index)
            case .truncatedFatHeader:
                return .localized("The universal binary header lists more architectures than the file contains.")
            case .noDeviceNativeSlice:
                return .localized("This binary has no arm64 slice, so it cannot be signed for a device.")
            case .unsupportedArchitecture(let architecture):
                return .localized("This slice targets %@, which iOS devices do not run.", arguments: architecture)
            case .encryptedBinary(let architecture, let id):
                return .localized("The %@ slice is still encrypted (cryptid %lld).", arguments: architecture, Int(id))
            case .missingCodeSignature(let architecture):
                return .localized("The %@ slice carries no code signature.", arguments: architecture)
            }
        }
}
