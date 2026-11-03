import Foundation
import NimbleExtensions

enum LibraryWorkspaceSection: String, CaseIterable, Identifiable {
    case apps, files
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apps: return .localized("Apps")
        case .files: return .localized("Files")
        }
    }
}

enum ActivityWorkspaceSection: String, CaseIterable, Identifiable {
    case downloads, tasks, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .downloads: return .localized("Downloads")
        case .tasks: return .localized("Tasks")
        case .logs: return .localized("Logs")
        }
    }
}

/// Keeps existing URL/Live Activity routes useful after merging destinations.
enum WorkspaceRoute: Equatable {
    case home, apps, files, appStore, downloads, tasks, logs, settings

    static func resolve(host: String) -> Self? {
        switch host.lowercased() {
        case "home": return .home
        case "library": return .apps
        case "files": return .files
        case "appstore": return .appStore
        case "activity", "downloads": return .downloads
        case "tasks": return .tasks
        case "logs": return .logs
        case "settings": return .settings
        default: return nil
        }
    }

    var tab: TabEnum {
        switch self {
        case .home: return .home
        case .apps, .files: return .library
        case .appStore: return .appStore
        case .downloads, .tasks, .logs: return .downloads
        case .settings: return .settings
        }
    }

    var librarySection: LibraryWorkspaceSection? {
        switch self {
        case .apps: return .apps
        case .files: return .files
        default: return nil
        }
    }

    var activitySection: ActivityWorkspaceSection? {
        switch self {
        case .downloads: return .downloads
        case .tasks: return .tasks
        case .logs: return .logs
        default: return nil
        }
    }
}
