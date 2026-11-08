import SwiftUI
import NimbleViews
import NimbleExtensions

/// The five-tab shell groups related tools instead of adding more tab-bar items.
/// Child pages reuse this navigation stack; they never add another navigation bar.
struct LibraryWorkspaceView: View {
    @ObservedObject private var selection = TabSelectionObserver.shared

    var body: some View {
        NBNavigationView(.localized("Library")) {
            VStack(spacing: 0) {
                Picker(.localized("Library workspace"), selection: $selection.librarySection) {
                    ForEach(LibraryWorkspaceSection.allCases) { section in Text(section.title).tag(section) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                switch selection.librarySection {
                case .apps, .signedApps:
                    LibraryView(ownsNavigationStack: false, workspaceSection: selection.librarySection)
                        .id(selection.librarySection)
                case .files: FilesTabView(ownsNavigationStack: false)
                }
            }
            .background(Theme.background)
        }

    }
}

struct ActivityWorkspaceView: View {
    @ObservedObject private var selection = TabSelectionObserver.shared

    var body: some View {
        NBNavigationView(.localized("Activity")) {
            VStack(spacing: 0) {
                Picker(.localized("Activity workspace"), selection: $selection.activitySection) {
                    ForEach(ActivityWorkspaceSection.allCases) { section in Text(section.title).tag(section) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                switch selection.activitySection {
                case .downloads: DownloadsTabView(ownsNavigationStack: false)
                case .tasks: TaskCenterView(ownsNavigationStack: false)
                case .logs: LogsHistoryView(inNavigationStack: false)
                }
            }
            .background(Theme.background)
        }
    }
}
