// `.task(id:)` re-measures directory sizes whenever its id changes, so the identity a library size
// measurement is keyed on has to be both exact and cheap. It is now a value type instead of a
// joined string; these tests pin that the change is allocation-only.
import Foundation
import XCTest
@testable import VexSign

final class LibrarySizeMeasurementKeyTests: XCTestCase {
    private let generation = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func key(
        generation: UUID? = nil,
        signed: [(uuid: String?, date: Date?)] = [],
        imported: [(uuid: String?, date: Date?)] = []
    ) -> LibrarySizeMeasurementKey {
        .make(generation: generation ?? self.generation, signed: signed, imported: imported)
    }

    // MARK: - Stability

    /// The common case: nothing changed, so nothing should be re-measured.
    func testIdenticalInputsProduceEqualKeys() {
        let signed: [(uuid: String?, date: Date?)] = [("a", date), ("b", date)]
        let imported: [(uuid: String?, date: Date?)] = [("c", nil)]
        XCTAssertEqual(key(signed: signed, imported: imported), key(signed: signed, imported: imported))
    }

    /// The generation changes on a file-system or Core Data notification, so every measurement must
    /// be redone even when the rows are identical.
    func testGenerationChangeInvalidates() {
        let signed: [(uuid: String?, date: Date?)] = [("a", date)]
        XCTAssertNotEqual(
            key(signed: signed),
            key(generation: UUID(), signed: signed)
        )
    }

    func testDateChangeInvalidates() {
        XCTAssertNotEqual(
            key(signed: [("a", date)]),
            key(signed: [("a", date.addingTimeInterval(1))])
        )
    }

    func testIdentityChangeInvalidates() {
        XCTAssertNotEqual(key(signed: [("a", date)]), key(signed: [("b", date)]))
    }

    /// Signed and unsigned rows are distinguished, matching the old "s:"/"i:" prefixes.
    func testSignedAndImportedRowsAreDistinguished() {
        XCTAssertNotEqual(key(signed: [("a", date)]), key(imported: [("a", date)]))
    }

    /// The old key joined in array order, so an order change produced a different key. Keeping that
    /// makes this an allocation change rather than a behaviour change.
    func testOrderIsSignificant() {
        XCTAssertNotEqual(
            key(signed: [("a", date), ("b", date)]),
            key(signed: [("b", date), ("a", date)])
        )
    }

    /// A missing uuid became the empty string in the old interpolation; it must still collapse to
    /// the same entry rather than becoming its own identity.
    func testNilUUIDMatchesAllMissingUUIDs() {
        XCTAssertEqual(key(signed: [(nil, date)]), key(signed: [("", date)]))
    }

    /// `nil` date was `0` in the old key because of `?? 0`. A row actually dated at the epoch is
    /// therefore indistinguishable from an undated one — preserved deliberately, since changing it
    /// would change when measurements fire.
    func testNilDateAndEpochDateCollapseAsBefore() {
        XCTAssertEqual(
            key(signed: [(("a"), nil)]),
            key(signed: [(("a"), Date(timeIntervalSince1970: 0))])
        )
    }

    // MARK: - Shape

    func testEntriesAreSignedThenImportedInInputOrder() {
        let built = key(signed: [("s1", date), ("s2", date)], imported: [("i1", date)])
        XCTAssertEqual(built.entries.map(\.id), ["s1", "s2", "i1"])
        XCTAssertEqual(built.entries.map(\.isSigned), [true, true, false])
    }

    /// The disabled key stands in when size sorting is off. It must never equal a real key, or
    /// turning size sorting on would skip the first measurement.
    func testDisabledKeyDoesNotMatchARealKey() {
        XCTAssertNotEqual(LibrarySizeMeasurementKey.disabled, key())
    }

    /// The disabled key is recomputed on every body evaluation while size sorting is off. It must
    /// compare equal to itself so `.task(id:)` does not restart, hence the fixed-shape empty list.
    func testDisabledKeyIsShapedLikeAnEmptyMeasurement() {
        XCTAssertEqual(LibrarySizeMeasurementKey.disabled.entries, [])
        XCTAssertEqual(LibrarySizeMeasurementKey.disabled, LibrarySizeMeasurementKey.disabled)
    }
}
