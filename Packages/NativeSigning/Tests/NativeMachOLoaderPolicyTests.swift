import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred synthetic command/range vectors. Not real binding/fixup bytecode,
/// platform execution, installed dependency resolution or signing/trust fixtures.
final class NativeMachOLoaderPolicyTests: XCTestCase {
    private static func le(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private static func put(_ value: Int, _ p: Int, in data: inout Data) { data.replaceSubrange(p..<(p + 4), with: le(value)) }
    private static func stringCommand(_ kind: Int, path: String, offset: Int) -> Data {
        let string = Data(path.utf8) + Data([0])
        let length = (offset + string.count + 7) & ~7
        return le(kind) + le(length) + le(offset) + Data(repeating: 0, count: offset - 12) + string + Data(repeating: 0, count: length - offset - string.count)
    }
    static func image(extra: Data = Data(), extraCount: Int = 0) -> Data {
        var data = NativeMachOMutationTests.image()
        let dylinker = stringCommand(0xe, path: "/usr/lib/dyld", offset: 12)
        let dependency = stringCommand(0xc, path: "/System/Library/Frameworks/UIKit.framework/UIKit", offset: 24)
        let version = le(0x32) + le(24) + le(2) + le(0x100000) + le(0x100000) + le(0)
        let commands = dylinker + dependency + version + extra
        put(7 + extraCount, 16, in: &data); put(264 + commands.count, 20, in: &data)
        data.replaceSubrange(296..<(296 + commands.count), with: commands)
        return data
    }
    func testExportAndMalformedChainedPayloads() throws {
        for kind in [0x80000034] {
            let command = Self.le(kind) + Self.le(16) + Self.le(4096) + Self.le(8)
            XCTAssertThrowsError(try NativeMachOLoaderPolicy.validate(Self.image(extra: command, extraCount: 1)))
        }
        let exportCommand = Self.le(0x80000033) + Self.le(16) + Self.le(4096) + Self.le(8)
        // Empty root plus six zero alignment bytes is a valid empty trie.
        try NativeMachOLoaderPolicy.validate(Self.image(extra: exportCommand, extraCount: 1))
        var malformed = Self.image(extra: exportCommand, extraCount: 1)
        malformed.replaceSubrange(4096..<4104, with: Data(repeating: 255, count: 8))
        XCTAssertThrowsError(try NativeMachOLoaderPolicy.validate(malformed))
        // All-empty legacy stream envelope is permitted; no hidden stream data.
        let emptyInfo = Self.le(0x80000022) + Self.le(48) + Data(repeating: 0, count: 40)
        try NativeMachOLoaderPolicy.validate(Self.image(extra: emptyInfo, extraCount: 1))
    }
    func testCanonicalSystemOnlyEnvelope() throws { try NativeMachOLoaderPolicy.validate(Self.image()) }
    func testSystemPathAllowlistRejectsTraversalRpathPrivateAndLookalikes() {
        for path in ["/usr/lib/libSystem.B.dylib", "/usr/lib/swift/libswiftCore.dylib", "/System/Library/Frameworks/Foundation.framework/Foundation"] {
            XCTAssertTrue(NativeMachOLoaderPolicy.isSystemDependency(path), path)
        }
        for path in ["@rpath/libswiftCore.dylib", "@executable_path/evil.dylib", "/usr/lib/../evil.dylib", "/usr//lib/libX.dylib",
            "/usr/lib/libX.dylib/evil", "/usr/lib/libX.dylib\n", "/System/Library/PrivateFrameworks/X.framework/X",
            "/System/Library/Frameworks/UIKit.framework/Evil", "/System/Library/Frameworks/UIKit.framework/UIKit/extra", "/tmp/libX.dylib"] {
            XCTAssertFalse(NativeMachOLoaderPolicy.isSystemDependency(path), path)
        }
    }
    func testUnknownRpathDuplicateAndForeignLibraryCommandsReject() throws {
        let extras = [Self.le(0x76543210) + Self.le(8),
            Self.stringCommand(0x8000001c, path: "/usr/lib", offset: 12),
            Self.stringCommand(0xc, path: "@rpath/libX.dylib", offset: 24),
            Self.stringCommand(0xc, path: "/System/Library/Frameworks/UIKit.framework/UIKit", offset: 24)]
        for command in extras { XCTAssertThrowsError(try NativeMachOLoaderPolicy.validate(Self.image(extra: command, extraCount: 1))) }
    }
    func testLinkeditReferenceCannotPointToInstructionsSignatureOrPastEnd() throws {
        for offset in [512, 8192, Int(UInt32.max)] {
            let command = Self.le(0x26) + Self.le(16) + Self.le(offset) + Self.le(1)
            XCTAssertThrowsError(try NativeMachOLoaderPolicy.validate(Self.image(extra: command, extraCount: 1)))
        }
        let bounded = Self.le(0x26) + Self.le(16) + Self.le(4096) + Self.le(8)
        try NativeMachOLoaderPolicy.validate(Self.image(extra: bounded, extraCount: 1))
    }
    func testWrongPlatformAndUnterminatedCommandStringReject() throws {
        var simulator = Self.image()
        // The fixture puts build version after the two canonical string commands.
        let versionOffset = 296 + Self.stringCommand(0xe, path: "/usr/lib/dyld", offset: 12).count
            + Self.stringCommand(0xc, path: "/System/Library/Frameworks/UIKit.framework/UIKit", offset: 24).count
        Self.put(7, versionOffset + 8, in: &simulator)
        XCTAssertThrowsError(try NativeMachOLoaderPolicy.validate(simulator))
        var malformed = Self.stringCommand(0xc, path: "/usr/lib/libX.dylib", offset: 24)
        for index in 24..<malformed.count { malformed[index] = 65 }
        XCTAssertThrowsError(try NativeMachOLoaderPolicy.validate(Self.image(extra: malformed, extraCount: 1)))
    }
}
