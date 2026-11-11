import Foundation

/// The identity a library size measurement is keyed on.
///
/// `LibraryView` re-measures directory sizes through `.task(id:)`, which means the id is built and
/// compared on every body evaluation — and body evaluates the filtered/sorted arrays a dozen times.
/// The previous implementation built that id by interpolating a string per app and joining them:
///
///     _sizeGeneration.uuidString + (signed.map { "s:\(uuid):\(date)" } + imported.map { ... })
///         .joined(separator: "|")
///
/// For a 900-app library that is ~900 string allocations and a ~46 KiB joined string, per body
/// evaluation, per paint — to answer a single `==`. That is main-thread work proportional to the
/// library, repeated, for a comparison that almost never changes.
///
/// This type carries exactly the same information with value semantics: no interpolation, no join,
/// and `==` short-circuits on the generation UUID before touching the entry list.
///
/// ## Why it is a separate type
///
/// It is pure and free of Core Data, so the equality rules that decide whether the disk is walked
/// again can be tested without a view, a managed object context, or a filesystem.
struct LibrarySizeMeasurementKey: Equatable, Sendable {
    /// Changes when something outside the row data invalidates every measurement (a file-system
    /// change notification, a Core Data save).
    let generation: UUID

    /// One entry per library row, in the order the rows were given.
    ///
    /// Order-sensitive on purpose: it matches the previous string key, which joined in array order.
    /// Preserving that keeps this a pure allocation change rather than a behaviour change.
    let entries: [Entry]

    struct Entry: Equatable, Sendable {
        let id: String
        /// The row's date. `nil` is distinct from any real date, and from `0`.
        let date: TimeInterval?
        let isSigned: Bool

        init(id: String, date: Date?, isSigned: Bool) {
            self.id = id
            self.date = date?.timeIntervalSince1970
            self.isSigned = isSigned
        }
    }

    init(generation: UUID, signed: [Entry], imported: [Entry]) {
        self.generation = generation
        self.entries = signed + imported
    }

    /// Builds the key from the two library arrays, in the order the view holds them.
    static func make(
        generation: UUID,
        signed: [(uuid: String?, date: Date?)],
        imported: [(uuid: String?, date: Date?)]
    ) -> LibrarySizeMeasurementKey {
        LibrarySizeMeasurementKey(
            generation: generation,
            signed: signed.map { Entry(id: $0.uuid ?? "", date: $0.date, isSigned: true) },
            imported: imported.map { Entry(id: $0.uuid ?? "", date: $0.date, isSigned: false) }
        )
    }

    /// The key used when size sorting is not selected: measurement is disabled, and the id must not
    /// change just because the library did.
    static let disabled = LibrarySizeMeasurementKey(generation: UUID(), signed: [], imported: [])
}
