import Foundation

struct AccountInventoryScope: Equatable {
    let backend: ObjectIdentifier
    let context: UUID
    let team: String
}

/// Value-type fence used on the account manager's main actor. A scope match alone
/// is insufficient when two reads of the same account complete out of order.
struct AccountInventoryReadGate {
    struct Ticket: Equatable {
        fileprivate let id: UUID
        fileprivate let scope: AccountInventoryScope
    }
    private var latest: Ticket?
    mutating func begin(_ scope: AccountInventoryScope) -> Ticket {
        let ticket = Ticket(id: UUID(), scope: scope)
        latest = ticket
        return ticket
    }
    mutating func invalidate() { latest = nil }
    func accepts(_ ticket: Ticket, current: AccountInventoryScope?) -> Bool {
        latest == ticket && current == ticket.scope
    }
}
