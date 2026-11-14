import SwiftUI
import UIKit
import NimbleViews
import NimbleExtensions

/// Evidence from this sandbox only. There is deliberately no overall "ready" score.
struct CompanionSetupEvidence {
    let sideStoreHandler: Bool
    let liveContainerHandler: Bool
    let vexSignPairingFile: Bool

}

struct CompanionSetupDiagnosticsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var evidence: CompanionSetupEvidence?
    @State private var checkedAt: Date?

    var body: some View {
        NBList(.localized("Companion Setup Diagnostics")) {
            Section {
                if let evidence {
                    evidenceRow(.localized("SideStore URL handler"), present: evidence.sideStoreHandler)
                    evidenceRow(.localized("LiveContainer URL handler"), present: evidence.liveContainerHandler)
                    evidenceRow(.localized("VexSign pairing file"), present: evidence.vexSignPairingFile)
                } else {
                    ProgressView()
                }
                Button(.localized("Refresh local checks")) { refresh() }
                if let checkedAt {
                    LabeledContent(.localized("Checked at")) {
                        Text(checkedAt, style: .time)
                    }
                }
            } header: {
                Text(.localized("Locally detectable"))
            } footer: {
                Text(.localized("URL handlers are not app identity verification. A VexSign pairing file is not proof of a valid pair and says nothing about SideStore's private pairing configuration."))
            }

            Section {
                unknownRow(.localized("Apple-account login & 2FA"), detail: .localized("Check your account inside SideStore. VexSign cannot inspect that session."))
                unknownRow(.localized("SideStore renewal"), detail: .localized("Check app expiry and the latest refresh result inside SideStore. There is no cross-app completion signal here."))
                unknownRow(.localized("VPN & device connectivity"), detail: .localized("Check the VPN and pairing requirements for the companion version you installed. A pairing file alone does not verify connectivity."))
                unknownRow(.localized("LiveContainer signing mode & JIT"), detail: .localized("Check the active signing mode and guest requirements inside LiveContainer. Opening its URL scheme does not test guest execution."))
            } header: {
                Text(.localized("Check in companion apps"))
            }

            Section {
                NavigationLink(destination: JITSettingsView()) {
                    Label(.localized("VexSign JIT & pairing tools"), systemImage: "bolt.badge.automatic.fill")
                }
                Link(.localized("SideStore setup guide"), destination: URL(string: "https://docs.sidestore.io/")!)
                Link(.localized("LiveContainer project & instructions"), destination: URL(string: "https://github.com/LiveContainer/LiveContainer")!)
            } footer: {
                Text(.localized("No Apple credentials, certificates, pairing secrets or guest data are requested by these checks. VexSign does not mark a companion workflow successful based on detection alone."))
            }
        }
        .onAppear(perform: refresh)
        .nbOnChange(of: scenePhase) { phase in
            if phase == .active { refresh() }
        }
    }

    private func evidenceRow(_ title: String, present: Bool) -> some View {
        LabeledContent {
            Label(present ? String.localized("Detected") : String.localized("Not detected"), systemImage: present ? "doc.text.magnifyingglass" : "questionmark.circle")
                .foregroundStyle(.secondary)
        } label: { Text(title) }
    }

    private func unknownRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "questionmark.circle").font(.headline)
            Text(.localized("Not verified by VexSign")).font(.caption.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func refresh() {
        evidence = CompanionSetupEvidence(
            sideStoreHandler: UIApplication.shared.canOpenURL(URL(string: "sidestore://")!),
            liveContainerHandler: UIApplication.shared.canOpenURL(URL(string: "livecontainer://")!),
            vexSignPairingFile: PairingBridge.hasPairingFile
        )
        checkedAt = Date()
    }
}
