import Foundation
import XCTest
@testable import VexSign

final class AccountInventoryReadGateTests: XCTestCase {
    func testLateReadCannotPublishAcrossScopeOrOverwriteNewerRefresh() {
        let backend = NSObject(), replacement = NSObject(), context = UUID()
        let a = AccountInventoryScope(backend: ObjectIdentifier(backend), context: context, team: "A")
        var gate = AccountInventoryReadGate()
        let old = gate.begin(a), current = gate.begin(a)
        XCTAssertFalse(gate.accepts(old, current: a))
        XCTAssertTrue(gate.accepts(current, current: a))
        XCTAssertFalse(gate.accepts(current, current: nil))
        XCTAssertFalse(gate.accepts(current, current: .init(backend: a.backend, context: context, team: "B")))
        XCTAssertFalse(gate.accepts(current, current: .init(backend: a.backend, context: UUID(), team: "A")))
        XCTAssertFalse(gate.accepts(current, current: .init(backend: ObjectIdentifier(replacement), context: context, team: "A")))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(current, current: a))
    }
}
