//
//  MachOInspector.swift
//  VexSign
//
//  Structured, read-only Mach-O reporting for the files an IPA actually carries.
//
//  `MachOReader` answers one question (which dylibs does this binary load) and
//  `ExecutablePreflight` answers another (is this slice signed-incompatible), both with a
//  deliberately small, total result. This type answers the question the explorer and the
//  signing sheet ask: what *is* this binary — which architectures, what minimum system,
//  which libraries and search paths, is it encrypted, does it still carry a code signature —
//  and what about it deserves the user's attention.
//
//  Everything here is bounds-checked and side-effect free. Parsing never mutates, never
//  allocates proportional to a declared size, and returns typed diagnostics instead of
//  throwing, because a malformed binary is a fact to display rather than a reason to fail.
//

import Foundation
import NimbleExtensions

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
            case 0x0100000c: return subtype == 2 ? .arm64e : .arm64
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

    // MARK: - Load command identifiers

    private static let loadDylib: UInt32 = 0x0c
    private static let lazyLoadDylib: UInt32 = 0x20
    private static let loadWeakDylib: UInt32 = 0x8000_0018
    private static let reexportDylib: UInt32 = 0x8000_001f
    private static let runtimeSearchPath: UInt32 = 0x8000_001c
    private static let codeSignature: UInt32 = 0x1d
    private static let encryptionInfo: UInt32 = 0x21
    private static let encryptionInfo64: UInt32 = 0x2c
    private static let buildVersion: UInt32 = 0x32
    private static let versionMinMacOSX: UInt32 = 0x24
    private static let versionMinIPhoneOS: UInt32 = 0x25
    private static let versionMinTVOS: UInt32 = 0x2f
    private static let versionMinWatchOS: UInt32 = 0x30

    private static let maxCommands = 65_536
    private static let maxCommandBytes = 16 * 1024 * 1024
    private static let maxSlices = 64

    // MARK: - Entry points

    static func inspect(fileAt url: URL) -> Inspection {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .empty } // try? ok: reported as notMachO
        return inspect(data)
    }

    static func inspect(_ data: Data) -> Inspection {
        guard let magic = MachOReader.u32(data, at: 0, bigEndian: true) else { return .empty }

        if magic == MachOReader.fat || magic == MachOReader.fat64 {
            return inspectFat(data, magic: magic)
        }
        // Thin binaries carry their magic in host order; re-read little-endian to compare.
        guard let thin = MachOReader.u32(data, at: 0, bigEndian: false), isThinMagic(thin) else {
            return .empty
        }
        var issues: [Issue] = []
        guard let slice = inspectSlice(data, range: 0..<data.count, issues: &issues) else {
            return Inspection(slices: [], issues: issues.isEmpty ? [.truncatedHeader] : issues, isUniversal: false)
        }
        return Inspection(slices: [slice], issues: issues, isUniversal: false)
    }

    // MARK: - Fat containers

    private static func inspectFat(_ data: Data, magic: UInt32) -> Inspection {
        let entrySize = magic == MachOReader.fat ? 20 : 32
        var issues: [Issue] = []

        guard let declared = MachOReader.u32(data, at: 4, bigEndian: true),
              Int(declared) <= maxSlices,
              Int(declared) <= max(0, data.count - 8) / entrySize else {
            return Inspection(slices: [], issues: [.truncatedFatHeader], isUniversal: true)
        }
        let tableEnd = 8 + Int(declared) * entrySize

        var slices: [Slice] = []
        var ranges: [(range: Range<Int>, cpu: UInt32)] = []
        var truncated = false

        for index in 0..<Int(declared) {
            let entry = 8 + index * entrySize
            guard let cpu = MachOReader.u32(data, at: entry, bigEndian: true) else {
                truncated = true
                break
            }
            let start: UInt64?
            let size: UInt64?
            if entrySize == 20 {
                start = MachOReader.u32(data, at: entry + 8, bigEndian: true).map(UInt64.init)
                size = MachOReader.u32(data, at: entry + 12, bigEndian: true).map(UInt64.init)
            } else {
                start = wide(data, at: entry + 8)
                size = wide(data, at: entry + 16)
            }
            guard let start, let size,
                  start >= UInt64(tableEnd), start <= UInt64(data.count),
                  size >= 28, size <= UInt64(data.count) - start else {
                truncated = true
                continue
            }
            ranges.append((Int(start)..<Int(start + size), cpu))
        }

        if truncated { issues.append(.truncatedFatHeader) }

        // Slice ranges must not overlap: a command in one slice may not borrow bytes from another.
        let ordered = ranges.sorted { $0.range.lowerBound < $1.range.lowerBound }
        if ordered.count > 1 {
            for index in 1..<ordered.count where ordered[index - 1].range.upperBound > ordered[index].range.lowerBound {
                issues.append(.truncatedFatHeader)
                return Inspection(slices: [], issues: issues, isUniversal: true)
            }
        }

        for range in ordered {
            if let slice = inspectSlice(data, range: range.range, issues: &issues) {
                slices.append(slice)
            }
        }
        if slices.isEmpty, !issues.contains(.truncatedFatHeader) {
            issues.append(.truncatedFatHeader)
        }
        return Inspection(slices: slices, issues: issues, isUniversal: true)
    }

    private static func wide(_ data: Data, at offset: Int) -> UInt64? {
        guard let high = MachOReader.u32(data, at: offset, bigEndian: true),
              let low = MachOReader.u32(data, at: offset + 4, bigEndian: true) else { return nil }
        return (UInt64(high) << 32) | UInt64(low)
    }

    private static func isThinMagic(_ magic: UInt32) -> Bool {
        magic == MachOReader.machO64 || magic == MachOReader.machO64Swapped
            || magic == 0xfeedface || magic == 0xcefaedfe
    }

    // MARK: - One slice

    private static func inspectSlice(_ data: Data, range: Range<Int>, issues: inout [Issue]) -> Slice? {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return nil }
        guard let raw = MachOReader.u32(data, at: range.lowerBound, bigEndian: false) else {
            return nil
        }
        let bigEndian: Bool
        let headerSize: Int
        switch raw {
        case MachOReader.machO64: bigEndian = false; headerSize = 32
        case MachOReader.machO64Swapped: bigEndian = true; headerSize = 32
        case 0xfeedface: bigEndian = false; headerSize = 28
        case 0xcefaedfe: bigEndian = true; headerSize = 28
        default: return nil
        }

        func word(_ relative: Int) -> UInt32? {
            guard relative >= 0, range.count - relative >= 4 else { return nil }
            return MachOReader.u32(data, at: range.lowerBound + relative, bigEndian: bigEndian)
        }

        guard range.count >= headerSize,
              let cpu = word(4), let subtype = word(8),
              let commandCount = word(16), let commandBytes = word(20) else {
            issues.append(.truncatedHeader)
            return nil
        }
        guard commandCount <= maxCommands, commandBytes <= maxCommandBytes,
              Int(commandBytes) <= range.count - headerSize,
              Int(commandCount) <= max(Int(commandBytes) / 8, 0) else {
            issues.append(.truncatedHeader)
            return nil
        }

        let architecture = Architecture.cpuType(cpu, subtype: subtype)
        if !architecture.isDeviceNative {
            issues.append(.unsupportedArchitecture(architecture.description))
        }

        let end = headerSize + Int(commandBytes)
        var offset = headerSize
        var installNames: [String] = []
        var weakInstallNames: [String] = []
        var reexported: [String] = []
        var searchPaths: [String] = []
        var minimumSystem: UInt32?
        var sdk: UInt32?
        var platform: String?
        var encryptionID: UInt32?
        var hasCodeSignature = false

        for index in 0..<Int(commandCount) {
            guard offset <= end - 8, let command = word(offset), let length = word(offset + 4) else {
                issues.append(.malformedLoadCommands(commandIndex: index))
                break
            }
            guard length >= 8, length % 4 == 0, Int(length) <= end - offset else {
                issues.append(.malformedLoadCommands(commandIndex: index))
                break
            }
            let commandEnd = offset + Int(length)

            func commandWord(_ relative: Int) -> UInt32? {
                guard relative >= 0, Int(length) - relative >= 4 else { return nil }
                return MachOReader.u32(data, at: range.lowerBound + offset + relative, bigEndian: bigEndian)
            }
            /// A `lc_str` name inside this command: it must start after the command's fixed
            /// fields and before its end, so a name can neither overlap the header nor escape.
            func name(at relative: Int, minimum: UInt32) -> String? {
                guard let nameOffset = commandWord(relative),
                      nameOffset >= minimum,
                      nameOffset < length else { return nil }
                return cString(in: data, from: range.lowerBound + offset + Int(nameOffset),
                               limit: range.lowerBound + commandEnd)
            }

            switch command {
            case loadDylib, lazyLoadDylib:
                guard length >= 24, let name = name(at: 8, minimum: 24) else {
                    issues.append(.invalidStringOffset(commandIndex: index))
                    break
                }
                installNames.append(name)
            case loadWeakDylib:
                guard length >= 24, let name = name(at: 8, minimum: 24) else {
                    issues.append(.invalidStringOffset(commandIndex: index))
                    break
                }
                weakInstallNames.append(name)
            case reexportDylib:
                guard length >= 24, let name = name(at: 8, minimum: 24) else {
                    issues.append(.invalidStringOffset(commandIndex: index))
                    break
                }
                reexported.append(name)
            case runtimeSearchPath:
                guard length >= 12, let name = name(at: 8, minimum: 12) else {
                    issues.append(.invalidStringOffset(commandIndex: index))
                    break
                }
                searchPaths.append(name)
            case codeSignature:
                hasCodeSignature = true
            case encryptionInfo, encryptionInfo64:
                guard length >= (command == encryptionInfo64 ? 24 : 20),
                      let identifier = commandWord(16) else { break }
                encryptionID = identifier
            case buildVersion:
                guard length >= 24, let value = commandWord(12) else { break }
                minimumSystem = value
                sdk = commandWord(16)
                if let value = commandWord(8) { platform = Self.platformName(value) }
            case versionMinMacOSX, versionMinIPhoneOS, versionMinTVOS, versionMinWatchOS:
                guard length >= 16, let value = commandWord(8) else { break }
                if minimumSystem == nil { minimumSystem = value }
                sdk = sdk ?? commandWord(12)
                if platform == nil {
                    switch command {
                    case versionMinMacOSX: platform = "macOS"
                    case versionMinIPhoneOS: platform = "iOS"
                    case versionMinTVOS: platform = "tvOS"
                    default: platform = "watchOS"
                    }
                }
            default:
                break
            }

            offset = commandEnd
        }

        if let encryptionID, encryptionID != 0 {
            issues.append(.encryptedBinary(architecture.description, encryptionID: encryptionID))
        }
        if !hasCodeSignature {
            issues.append(.missingCodeSignature(architecture.description))
        }

        return Slice(
            architecture: architecture,
            cpuSubtype: subtype,
            is64Bit: headerSize == 32,
            commandCount: Int(commandCount),
            installNames: deduplicated(installNames),
            weakInstallNames: deduplicated(weakInstallNames),
            reexportedInstallNames: deduplicated(reexported),
            runtimeSearchPaths: deduplicated(searchPaths),
            minimumSystemVersion: minimumSystem.map(Self.versionString),
            sdkVersion: sdk.map(Self.versionString),
            platform: platform,
            encryptionID: encryptionID.flatMap { $0 == 0 ? nil : $0 },
            hasCodeSignature: hasCodeSignature
        )
    }

    // MARK: - Helpers

    /// `nil` when the file has no device-native slice — the fact signing cares about.
    static func deviceNativeCompatibility(_ inspection: Inspection) -> Issue? {
        inspection.deviceNativeSlices.isEmpty ? .noDeviceNativeSlice : nil
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func cString(in data: Data, from start: Int, limit: Int) -> String? {
        guard start >= 0, start < limit, limit <= data.count else { return nil }
        let base = data.startIndex
        var end = start
        while end < limit, data[base + end] != 0 { end += 1 }
        guard end > start, end < limit else { return nil }
        return String(decoding: data[(base + start)..<(base + end)], as: UTF8.self)
    }

    /// `x.y` or `x.y.z` from the packed `xxxx.yy.zz` form.
    static func versionString(_ packed: UInt32) -> String {
        let major = packed >> 16
        let minor = (packed >> 8) & 0xff
        let patch = packed & 0xff
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    static func platformName(_ platform: UInt32) -> String {
        switch platform {
        case 1: "macOS"
        case 2: "iOS"
        case 3: "tvOS"
        case 4: "watchOS"
        case 5: "bridgeOS"
        case 6: "Mac Catalyst"
        case 7: "iOS Simulator"
        case 8: "tvOS Simulator"
        case 9: "watchOS Simulator"
        case 10: "DriverKit"
        case 11: "visionOS"
        case 12: "visionOS Simulator"
        default: String(format: "platform 0x%08x", platform)
        }
    }
}
