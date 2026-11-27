import Foundation
import XCTest
@testable import VexSign

/// ZIP mode bits are attacker-controlled. Extraction may honour executable
/// bits, but it must never create setuid/setgid/sticky or group-writable files
/// inside the app's container.
final class ArchiveFileAttributesTests: XCTestCase {
    func testSpecialAndGroupWriteBitsAreRemovedFromFiles() {
        for declared in [0o4777, 0o2777, 0o1777, 0o777, 0o766, 0o666] {
            let attributes = [FileAttributeKey.posixPermissions: NSNumber(value: declared)]
            let safe = ArchiveFileAttributesPolicy.sanitized(attributes, isDirectory: false)
            let mode = (safe[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(mode, declared & 0o755, "declared \(String(declared, radix: 8))")
            XCTAssertEqual(mode! & 0o7000, 0)
            XCTAssertEqual(mode! & 0o022, 0)
        }
    }

    func testExecutableAndReadableFilesAreUnchanged() {
        for declared in [0o600, 0o644, 0o700, 0o755] {
            let attributes = [FileAttributeKey.posixPermissions: NSNumber(value: declared)]
            XCTAssertEqual(
                (ArchiveFileAttributesPolicy.sanitized(attributes, isDirectory: false)[.posixPermissions] as? NSNumber)?.intValue,
                declared
            )
        }
    }

    func testDirectoryAndFallbackModesAreBounded() {
        let dangerous = [FileAttributeKey.posixPermissions: NSNumber(value: 0o3777)]
        XCTAssertEqual(
            (ArchiveFileAttributesPolicy.sanitized(dangerous, isDirectory: true)[.posixPermissions] as? NSNumber)?.intValue,
            0o755
        )
        XCTAssertEqual(
            (ArchiveFileAttributesPolicy.sanitized([:], isDirectory: false)[.posixPermissions] as? NSNumber)?.intValue,
            0o644
        )
        XCTAssertEqual(
            (ArchiveFileAttributesPolicy.sanitized([:], isDirectory: true)[.posixPermissions] as? NSNumber)?.intValue,
            0o755
        )
    }

    func testUnrelatedAttributesArePreserved() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: 0o4755),
            .modificationDate: date
        ]
        let safe = ArchiveFileAttributesPolicy.sanitized(attributes, isDirectory: false)
        XCTAssertEqual(safe[.modificationDate] as? Date, date)
        XCTAssertEqual((safe[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }
}
