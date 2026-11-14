import SwiftUI
import XCTest
@testable import VexSign

final class IdentifiedArrayBindingTests: XCTestCase {
    private struct Row: Identifiable, Equatable {
        let id: Int
        var title: String
    }

    @MainActor
    func testBindingFollowsIdentityAfterInsertionAndReordering() {
        var rows = [Row(id: 1, title: "First"), Row(id: 2, title: "Second")]
        let source = Binding(get: { rows }, set: { rows = $0 })
        let row = IdentifiedArrayBinding.element(rows[1], in: source)
        rows.insert(Row(id: 3, title: "New"), at: 0)
        rows.reverse()
        row.wrappedValue.title = "Updated"
        XCTAssertEqual(rows.first { $0.id == 2 }?.title, "Updated")
        XCTAssertEqual(rows.first { $0.id == 1 }?.title, "First")
        XCTAssertEqual(rows.first { $0.id == 3 }?.title, "New")
    }

    @MainActor
    func testRemovedRowCanStillRenderAndCannotResurrectItself() {
        let snapshot = Row(id: 1, title: "Removed")
        var rows = [snapshot, Row(id: 2, title: "Keep")]
        let source = Binding(get: { rows }, set: { rows = $0 })
        let row = IdentifiedArrayBinding.element(snapshot, in: source)
        rows.removeFirst()
        XCTAssertEqual(row.wrappedValue, snapshot)
        row.wrappedValue.title = "Late toggle during animation"
        XCTAssertEqual(rows, [Row(id: 2, title: "Keep")])
    }

    @MainActor
    func testGetterUsesCurrentValueNotInitialSnapshot() {
        var rows = [Row(id: 1, title: "Original")]
        let source = Binding(get: { rows }, set: { rows = $0 })
        let row = IdentifiedArrayBinding.element(rows[0], in: source)
        rows[0].title = "Changed elsewhere"
        XCTAssertEqual(row.wrappedValue.title, "Changed elsewhere")
        rows.removeAll()
        XCTAssertEqual(row.wrappedValue.title, "Original")
    }

    @MainActor
    func testNestedFileBindingSurvivesRemovalOfItsParent() {
        struct Group: Identifiable {
            let id: Int
            var files: [Row]
        }
        var groups = [Group(id: 1, files: [Row(id: 2, title: "Library")])]
        let source = Binding(get: { groups }, set: { groups = $0 })
        let group = IdentifiedArrayBinding.element(groups[0], in: source)
        let file = IdentifiedArrayBinding.element(group.wrappedValue.files[0], in: group.files)
        groups.removeAll()
        XCTAssertEqual(file.wrappedValue.title, "Library")
        file.wrappedValue.title = "Late editor callback"
        XCTAssertTrue(groups.isEmpty)
    }
}
