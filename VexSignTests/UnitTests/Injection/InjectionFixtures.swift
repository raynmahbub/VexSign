//
//  InjectionFixtures.swift
//  VexSignTests
//
//  Deterministic, synthetic fixtures only. No real tweak, IPA, certificate or
//  proprietary application content is present in this repository.
//

import Foundation
@testable import VexSign

enum InjectionFixtures {
    // MARK: - ar / deb

    static func deb(
        control: String,
        files: [(path: String, data: Data, type: String)],
        dataMemberName: String = "data.tar",
        controlMemberName: String = "control.tar"
    ) -> Data {
        let controlTar = tar(files: [("control", Data(control.utf8), "0")])
        let dataTar = tar(files: files)
        var output = Data("!<arch>\n".utf8)
        appendArMember("debian-binary", Data("2.0\n".utf8), to: &output)
        appendArMember(controlMemberName, controlTar, to: &output)
        appendArMember(dataMemberName, dataTar, to: &output)
        return output
    }

    private static func appendArMember(_ name: String, _ data: Data, to archive: inout Data) {
        var header = Array(repeating: UInt8(ascii: " "), count: 60)
        func write(_ text: String, _ start: Int, _ width: Int) {
            let bytes = Array(text.utf8).prefix(width)
            for (index, byte) in bytes.enumerated() { header[start + index] = byte }
        }
        write(name, 0, 16)
        write("0", 16, 12)
        write("0", 28, 6)
        write("0", 34, 6)
        write("100644", 40, 8)
        write(String(data.count), 48, 10)
        header[58] = UInt8(ascii: "`")
        header[59] = UInt8(ascii: "\n")
        archive.append(contentsOf: header)
        archive.append(data)
        if data.count % 2 == 1 { archive.append(UInt8(ascii: "\n")) }
    }

    /// A minimal USTAR writer. Only regular files, directories and symlinks are
    /// needed to exercise the inspector's acceptance and rejection paths.
    static func tar(files: [(path: String, data: Data, type: String)]) -> Data {
        var output = Data()
        for entry in files {
            var header = Array(repeating: UInt8(0), count: 512)
            func write(_ text: String, _ start: Int, _ width: Int) {
                let bytes = Array(text.utf8).prefix(width)
                for (index, byte) in bytes.enumerated() { header[start + index] = byte }
            }
            write(entry.path, 0, 100)
            write("0000644", 100, 8)
            write("0000000", 108, 8)
            write("0000000", 116, 8)
            let octalSize = String(entry.data.count, radix: 8)
            write(String(repeating: "0", count: max(0, 11 - octalSize.count)) + octalSize, 124, 12)
            write("00000000000", 136, 12)
            for index in 148..<156 { header[index] = UInt8(ascii: " ") }
            header[156] = UInt8(ascii: entry.type.first ?? "0")
            write("ustar", 257, 5)
            header[262] = 0
            write("00", 263, 2)
            let checksum = header.reduce(0) { Int($0) + Int($1) }
            let checksumText = String(checksum, radix: 8)
            let padded = String(repeating: "0", count: max(0, 6 - checksumText.count)) + checksumText + "\0 "
            write(padded, 148, 8)
            output.append(contentsOf: header)
            output.append(entry.data)
            let remainder = entry.data.count % 512
            if remainder != 0 { output.append(contentsOf: Array(repeating: UInt8(0), count: 512 - remainder)) }
        }
        output.append(contentsOf: Array(repeating: UInt8(0), count: 1_024))
        return output
    }

    // MARK: - Mach-O

    /// A small arm64 Mach-O 64 header with one __TEXT segment and one stale
    /// LC_CODE_SIGNATURE. Enough trailing slack exists for one LC_LOAD_DYLIB.
    static func machO(
        sectionOffset: Int = 1_024,
        loadPaths: [String] = [],
        includeCodeSignature: Bool = true
    ) -> Data {
        var loadCommands = Data()
        let segmentSize = 72 + 80
        appendU32(0x19, to: &loadCommands) // LC_SEGMENT_64
        appendU32(UInt32(segmentSize), to: &loadCommands)
        appendASCII("__TEXT", to: &loadCommands, width: 16)
        appendU64(0, to: &loadCommands)
        appendU64(UInt64(max(sectionOffset, 4_096)), to: &loadCommands)
        appendU64(0, to: &loadCommands)
        appendU64(UInt64(max(sectionOffset, 4_096)), to: &loadCommands)
        appendU32(0, to: &loadCommands)
        appendU32(0, to: &loadCommands)
        appendU32(1, to: &loadCommands) // one section
        appendU32(0, to: &loadCommands)
        appendASCII("__text", to: &loadCommands, width: 16)
        appendASCII("__TEXT", to: &loadCommands, width: 16)
        appendU64(0, to: &loadCommands)
        appendU64(128, to: &loadCommands)
        appendU32(UInt32(sectionOffset), to: &loadCommands)
        appendU32(0, to: &loadCommands)
        for _ in 0..<5 { appendU32(0, to: &loadCommands) }

        for path in loadPaths {
            let bytes = Array(path.utf8) + [0]
            let size = (24 + bytes.count + 7) & ~7
            appendU32(0x0c, to: &loadCommands)
            appendU32(UInt32(size), to: &loadCommands)
            appendU32(24, to: &loadCommands)
            appendU32(0x10000, to: &loadCommands)
            appendU32(0x10000, to: &loadCommands)
            appendU32(0x10000, to: &loadCommands)
            loadCommands.append(contentsOf: bytes)
            loadCommands.append(contentsOf: Array(repeating: UInt8(0), count: size - 24 - bytes.count))
        }
        if includeCodeSignature {
            appendU32(0x1d, to: &loadCommands)
            appendU32(16, to: &loadCommands)
            appendU32(0, to: &loadCommands)
            appendU32(0, to: &loadCommands)
        }

        let fileSize = max(sectionOffset + 512, 4_096)
        var data = Data(repeating: 0, count: fileSize)
        let header: [UInt32] = [
            0xfeedfacf, 0x0100000c, 0, 2,
            UInt32(includeCodeSignature ? 2 + UInt32(loadPaths.count) : 1 + UInt32(loadPaths.count)),
            UInt32(loadCommands.count), 0, 0
        ]
        for (index, value) in header.enumerated() {
            for byte in 0..<4 {
                data[index * 4 + byte] = UInt8((value >> UInt32(byte * 8)) & 0xff)
            }
        }
        data.replaceSubrange(32..<(32 + loadCommands.count), with: loadCommands)
        return data
    }

    static func fat(slices: [Data]) -> Data {
        var output = Data()
        appendU32(0xcafebabe, to: &output)
        appendU32(UInt32(slices.count), to: &output)
        var offset = 8 + slices.count * 20
        for slice in slices {
            appendU32(0x0100000c, to: &output)
            appendU32(0, to: &output)
            appendU32(UInt32(offset), to: &output)
            appendU32(UInt32(slice.count), to: &output)
            appendU32(0, to: &output)
            offset += slice.count
        }
        for slice in slices { output.append(slice) }
        return output
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        for byte in 0..<4 { data.append(UInt8((value >> UInt32(byte * 8)) & 0xff)) }
    }

    private static func appendU64(_ value: UInt64, to data: inout Data) {
        for byte in 0..<8 { data.append(UInt8((value >> UInt64(byte * 8)) & 0xff)) }
    }

    private static func appendASCII(_ text: String, to data: inout Data, width: Int) {
        let bytes = Array(text.utf8)
        data.append(contentsOf: bytes)
        data.append(contentsOf: Array(repeating: UInt8(0), count: max(0, width - bytes.count)))
    }

    // MARK: - Domain fixtures

    static func inspection(
        id: String = "com.example.tweak",
        name: String = "Example Tweak",
        depends: [String] = [],
        conflicts: [String] = [],
        dylibs: [String] = ["Library/MobileSubstrate/DynamicLibraries/Example.dylib"],
        installPaths: [String]? = nil,
        outcome: InjectionOutcome = .compatible
    ) -> TweakPackageInspection {
        TweakPackageInspection(
            fileName: "\(name).deb", packageID: id, name: name, version: "1.0",
            architecture: "iphoneos-arm64", maintainer: "Fixture Maintainer", description: "Fixture",
            depends: PackageRelationParser.parse(depends.joined(separator: ", ")),
            preDepends: [], conflicts: PackageRelationParser.parse(conflicts.joined(separator: ", ")),
            breaks: [], provides: [], ignoredScripts: [],
            installPaths: installPaths ?? dylibs,
            dylibs: dylibs, frameworks: [], bundles: [], filters: [:], filterErrors: [],
            layout: .rootful, findings: [], outcome: outcome
        )
    }

    static func configuration(
        id: String = "com.example.tweak",
        pattern: String = "com.example.app",
        excluded: [String] = []
    ) -> InjectionConfiguration {
        InjectionConfiguration(
            packageID: id, version: "1.0", enabled: true,
            bundleRules: [InjectionFilterRule(kind: .bundle, pattern: pattern)],
            executableRules: [], excludedBundleIDs: excluded,
            installPath: "@executable_path", provenance: "fixture"
        )
    }

    static func target(
        id: String = "main",
        bundleID: String = "com.example.app",
        executable: String = "ExampleApp",
        isMain: Bool = true
    ) -> InjectionTarget {
        InjectionTarget(id: id, displayName: executable, bundleIdentifier: bundleID,
                        executableName: executable, isMain: isMain)
    }

    static func tweak(id: UUID, versionID: UUID, name: String = "Fixture") -> ManagedTweak {
        ManagedTweak(
            id: id, name: name, isEnabled: true,
            versions: [TweakVersion(id: versionID, label: "1.0", components: [
                TweakComponent(fileName: "\(name).deb", fileType: .deb, fileSize: 128)
            ])],
            selectedVersionId: versionID
        )
    }
}
