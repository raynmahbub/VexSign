import XCTest
import Zip
@testable import VexSign

final class ArchiveTransferPolicyTests: XCTestCase {
    func testPairingUsesFastCompressionInsteadOfUncompressedPayload() {
        XCTAssertEqual(ArchiveTransferPolicy.compression(storedIndex: 0, compressForTransfer: true), .BestSpeed)
    }

    func testExportAndOtherPathsPreserveUserCompression() {
        for (index, selected) in ZipCompression.allCases.enumerated() {
            XCTAssertEqual(ArchiveTransferPolicy.compression(storedIndex: index, compressForTransfer: false), selected)
        }
    }

    func testPairingPreservesExplicitCompressionLevels() {
        for index in 1..<ZipCompression.allCases.count {
            XCTAssertEqual(ArchiveTransferPolicy.compression(storedIndex: index, compressForTransfer: true), ZipCompression.allCases[index])
        }
    }

    func testInvalidSettingsFallBackWithoutIndexingCrash() {
        for index in [-1, Int.min, 4, Int.max] {
            for transfer in [false, true] {
                XCTAssertEqual(ArchiveTransferPolicy.compression(storedIndex: index, compressForTransfer: transfer), .DefaultCompression)
            }
        }
    }
}
