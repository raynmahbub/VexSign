import SwiftUI

/// A presentation-only projection, not a persistence query. The environment model
/// observes the application catalog once, including changes from background merges.
@propertyWrapper
struct WorkspaceQuery<Element: WorkspaceDatedRecord>: DynamicProperty {
    enum Order { case stored, newestFirst, oldestFirst, name, manual }
    @EnvironmentObject private var workspace: WorkspaceViewModel
    private let keyPath: KeyPath<WorkspaceSnapshot, [Element]>
    private let order: Order

    init(_ keyPath: KeyPath<WorkspaceSnapshot, [Element]>, order: Order = .stored) {
        self.keyPath = keyPath
        self.order = order
    }

    var wrappedValue: [Element] {
        let records = workspace.snapshot[keyPath: keyPath]
        switch order {
        case .stored: return records
        case .newestFirst: return records.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .oldestFirst: return records.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        case .name: return records.sorted { $0.workspaceName < $1.workspaceName }
        case .manual: return records.sorted { $0.workspaceOrder < $1.workspaceOrder }
        }
    }
}
