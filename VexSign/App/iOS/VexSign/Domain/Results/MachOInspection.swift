import Foundation

enum MachOInspector {
    // MARK: - Model

    enum Architecture: Hashable, Sendable, CustomStringConvertible {
        case arm64
        case arm64e
        case arm64_32
        case armv7
        case armv7s
        case armv7k
        case i386
        case x86_64
        case unknown(UInt32)

        /// Whether this slice can run on an iOS device rather than a simulator or a Mac.
        var isDeviceNative: Bool {
            switch self {
            case .arm64, .arm64e: true
            default: false
            }
        }

        var description: String {
            switch self {
            case .arm64: "arm64"
            case .arm64e: "arm64e"
            case .arm64_32: "arm64_32"
            case .armv7: "armv7"
            case .armv7s: "armv7s"
            case .armv7k: "armv7k"
            case .i386: "i386"
            case .x86_64: "x86_64"
            case .unknown(let cpu): String(format: "cpu 0x%08x", cpu)
            }
        }

        static func cpuType(_ cpu: UInt32, subtype: UInt32) -> Architecture {
            switch cpu {
            // The high byte carries capability flags, not the subtype: every arm64e image
            // a current toolchain writes is `0x8000_0002` (pointer-authentication ABI).
            case 0x0100000c: return subtype & 0x00ff_ffff == 2 ? .arm64e : .arm64
            case 0x0200000c: return .arm64_32
            case 12: return .armv7
            case 11: return .armv7s
            case 0x01000007: return .x86_64
            case 7: return .i386
            default: return .unknown(cpu)
            }
        }
    }

    struct Slice: Equatable, Sendable {
        let architecture: Architecture
        let cpuSubtype: UInt32
        let is64Bit: Bool
        let commandCount: Int
        let installNames: [String]
        let weakInstallNames: [String]
        let reexportedInstallNames: [String]
        let runtimeSearchPaths: [String]
        /// Dotted minimum system version, e.g. `15.0`.
        let minimumSystemVersion: String?
        let sdkVersion: String?
        let platform: String?
        let encryptionID: UInt32?
        let hasCodeSignature: Bool

        var isEncrypted: Bool { (encryptionID ?? 0) != 0 }
        var linkedLibraries: [String] { installNames + weakInstallNames }
    }

    enum Issue: Hashable, Sendable {
        /// No recognisable Mach-O magic at the start of the file.
        case notMachO
        /// The header ends before the declared load-command region.
        case truncatedHeader
        /// A load command claims bytes outside the slice, so the rest of the list is unreadable.
        case malformedLoadCommands(commandIndex: Int)
        /// A load command's string offset points outside that command.
        case invalidStringOffset(commandIndex: Int)
        /// A fat header lists more slices than the file contains.
        case truncatedFatHeader
        /// The API user asked for a slice the file does not carry.
        case noDeviceNativeSlice
        /// A slice targets an architecture iOS devices cannot run.
        case unsupportedArchitecture(String)
        /// The slice is encrypted (App Store FairPlay); it cannot be inspected or re-signed as is.
        case encryptedBinary(String, encryptionID: UInt32)
        /// No `LC_CODE_SIGNATURE`, so the binary is unsigned or was stripped.
        case missingCodeSignature(String)


    }

    struct Inspection: Equatable, Sendable {
        let slices: [Slice]
        let issues: [Issue]
        let isUniversal: Bool

        static let empty = Inspection(slices: [], issues: [.notMachO], isUniversal: false)

        var architectures: [Architecture] { slices.map(\.architecture) }
        var deviceNativeSlices: [Slice] { slices.filter(\.architecture.isDeviceNative) }
        var isEncrypted: Bool { slices.contains(where: \.isEncrypted) }
        /// The libraries the arm64 slice loads, which is what signing and injection act on.
        var resolvedLinkedLibraries: [String] {
            (deviceNativeSlices.first ?? slices.first)?.linkedLibraries ?? []
        }
        var isEmpty: Bool { slices.isEmpty }
    }

}
