import SwiftUI
import NimbleExtensions

/// Says why the workspace is empty instead of showing an empty workspace.
///
/// `WorkspaceViewModel` keeps the last good snapshot when a refresh throws and
/// records the reason in `loadError`. Nothing rendered that sentence, so a store
/// the app could not read looked exactly like a library with nothing in it — and
/// an import that committed while the read was failing had nowhere visible to
/// appear, which reads as "the import did nothing". The banner shows the reason
/// and offers a retry.
struct WorkspaceLoadFailureBanner: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        if let reason = workspace.loadError {
            WorkspaceCard {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(.localized("The library could not be read"))
                            .font(.subheadline.weight(.semibold))
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 8)

                    Button(.localized("Retry")) { workspace.refresh() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}
