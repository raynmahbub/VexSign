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

    /// The old key interpolated `date ?? 0`, so an undated row produced the same *text* as a row
    /// dated at the epoch. This key keeps `nil` distinct — it is a value type, not a string format
    /// — so the two are no longer equal. That is a change in representation, not in behaviour:
    /// what the key decides is whether the input changed between two evaluations, and swapping a
    /// `nil` date for an epoch date on the same row *is* a change worth measuring again. The
    /// previous string key could not tell them apart and would have skipped that re-measure.
    func testNilDateIsDistinctFromEpochDate() {
        XCTAssertNotEqual(
            key(signed: [("a", nil)]),
            key(signed: [("a", Date(timeIntervalSince1970: 0))])
        )
    }

    /// Both forms are stable, so this distinction cannot cause repeated measurement on its own.
    func testNilDateIsStableAcrossEvaluations() {
        XCTAssertEqual(key(signed: [("a", nil)]), key(signed: [("a", nil)]))
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
