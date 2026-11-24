import Foundation
import XCTest
@testable import VexSign

final class WebManagerFilenamePolicyTests: XCTestCase {
    func testRejectsDirectoryReferencesAndControlCharacters() {
        for input in ["", ".", "..", "%2e", "%2e%2e", "folder/..", "file%00.ipa", "a\r\nb.ipa"] {
            XCTAssertNil(WebManagerFilenamePolicy.filename(input), input)
        }
    }

    func testNamesAreReducedToOneComponent() {
        XCTAssertEqual(WebManagerFilenamePolicy.filename("test.ipa"), "test.ipa")
        XCTAssertEqual(WebManagerFilenamePolicy.filename("folder%2Ftest.ipa"), "test.ipa")
        XCTAssertEqual(WebManagerFilenamePolicy.filename("folder/test.ipa"), "test.ipa")
    }

    func testContentDispositionQuotesFilename() {
        let filename = "a\"b\\c.ipa"
        XCTAssertEqual(WebManagerFilenamePolicy.contentDisposition(filename: filename),
                       "attachment; filename=\"a\\\"b\\\\c.ipa\"")
    }
}
