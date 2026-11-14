import SwiftUI

private struct WorkspaceBackgroundKey: EnvironmentKey {
    static let defaultValue = Color(uiColor: .systemGroupedBackground)
}
private struct WorkspaceCardKey: EnvironmentKey {
    static let defaultValue = Color(uiColor: .secondarySystemGroupedBackground)
}

public extension EnvironmentValues {
    var nbWorkspaceBackground: Color {
        get { self[WorkspaceBackgroundKey.self] }
        set { self[WorkspaceBackgroundKey.self] = newValue }
    }
    var nbWorkspaceCard: Color {
        get { self[WorkspaceCardKey.self] }
        set { self[WorkspaceCardKey.self] = newValue }
    }
}

/// Preserve the iOS 16 deployment target without deprecated call sites on newer SDKs.
public extension View {
    @ViewBuilder
    func nbOnChange<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
        if #available(iOS 17.0, tvOS 17.0, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}
