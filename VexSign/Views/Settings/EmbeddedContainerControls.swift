import SwiftUI
import NimbleExtensions

/// Shown only when the combined runtime is loaded in this process.
struct EmbeddedContainerControls: View {
    @ObservedObject private var tasks = UnifiedTaskCenter.shared
    @State private var openSideStore = false
    @State private var confirm = false
    @State private var failed = false
    private var busy: Bool { tasks.tasks.contains { $0.phase.isInProgress } }

    var body: some View {
        Section {
            Label(.localized("Embedded runtime loaded"), systemImage: "checkmark.seal")
            Text(.localized("LiveContainer and SideStore are included in this combined app. Switching sessions restarts the host process. Finish active work first; account credentials stay inside SideStore."))
                .font(.caption).foregroundStyle(.secondary)
            Button(.localized("Manage embedded LiveContainer")) { openSideStore = false; confirm = true }
            Button(.localized("Open embedded SideStore")) { openSideStore = true; confirm = true }
            if busy {
                Text(.localized("Finish active tasks before switching embedded sessions."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text(.localized("Built-in apps")) }
        .disabled(busy)
        .confirmationDialog(.localized("Switch embedded session?"), isPresented: $confirm, titleVisibility: .visible) {
            Button(.localized("Continue")) {
                guard !busy else { return }
                failed = !EmbeddedContainerRuntime.open(openSideStore ? .sideStore : .container)
            }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("Save your work. The current VexSign session closes while the embedded app opens. This does not confirm account login, signing or renewal."))
        }
        .alert(.localized("Embedded session could not open"), isPresented: $failed) {
            Button(.localized("OK"), role: .cancel) {}
        } message: {
            Text(.localized("The host did not accept the restart request. Return to the container home and check its signing or JIT setup. No external app was opened."))
        }
    }
}

struct EmbeddedContainerImportButton: View {
    let ipa: URL
    @ObservedObject private var tasks = UnifiedTaskCenter.shared
    @State private var confirm = false
    @Binding var staging: Bool
    @State private var error: String?
    private var busy: Bool { staging || tasks.tasks.contains { $0.phase.isInProgress } }

    var body: some View {
        VStack(alignment: .leading) {
            Button(.localized("Import prepared IPA into embedded LiveContainer")) { confirm = true }
                .disabled(busy)
            if staging { ProgressView(.localized("Preparing embedded import…")) }
        }
        .interactiveDismissDisabled(staging)
        .confirmationDialog(.localized("Import into the embedded container?"), isPresented: $confirm, titleVisibility: .visible) {
            Button(.localized("Prepare import and switch session")) {
                guard !busy else { return }
                Task { await stageAndOpen() }
            }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("The archive is checked and copied locally into the host inbox. Finish the import in LiveContainer. The host will restart this session; no upload or credential sharing occurs."))
        }
        .alert(.localized("Embedded import failed"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button(.localized("OK"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    @MainActor
    private func stageAndOpen() async {
        staging = true
        defer { staging = false }
        do {
            let source = ipa
            let accepted = try await Task.detached(priority: .userInitiated) {
                try EmbeddedContainerRuntime.stageIPA(source)
            }.value
            guard accepted else {
                error = .localized("The host could not stage this IPA. Complete or discard any previous prepared import in LiveContainer, check free space, then retry.")
                return
            }
            if !EmbeddedContainerRuntime.open(.container) {
                error = .localized("The IPA is staged, but the host could not restart. Open the container home to finish the prepared import.")
            }
        } catch { self.error = error.localizedDescription }
    }
}
