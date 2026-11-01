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
