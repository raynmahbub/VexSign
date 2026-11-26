// Guided bootstrap, in the existing Installation / Tunnel navigation.
// All advanced actions use the same PairingBridge/storage/native owners.
import SwiftUI
import NimbleViews
import NimbleExtensions

struct TunnelView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = DeviceBootstrapModel()
    @State private var hasVPNURLHandler = false
    @State private var confirmReplacement = false
    @State private var confirmDeletion = false
    @State private var confirmExport = false
    @State private var reviewedFingerprint: String?

    var body: some View {
        Group {
            Section {
                Text(.localized("VexSign must already be installed and launched through a legitimate development build, an eligible existing installer, or authorized distribution. It cannot self-install before bootstrap. A CI IPA is a build artifact, not an installation."))
                    .font(.footnote)
                Text(.localized("A signed IPA, its provisioning profile, device trust, Developer Mode and the installation transport are separate prerequisites. VexSign does not bypass Apple's restrictions."))
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text(.localized("1 · First installation is separate")) }

            Section {
                Label(model.routeTitle, systemImage: "info.circle")
                    .foregroundStyle(.orange)
                Text(model.routeDetail).font(.footnote).foregroundStyle(.secondary)
                Text(.localized("Developer Mode and Local Network permission are not automatically verified here. Enable Developer Mode in Settings → Privacy & Security when available, complete its restart/confirmation, unlock the iPhone and approve local access if iOS asks."))
                    .font(.footnote)
            } header: { Text(.localized("2 · OS route and permissions")) }

            Section {
                LabeledContent(.localized("Record"), value: model.pairing.title)
                Text(model.formatTitle).font(.caption).foregroundStyle(.secondary)
                Text(model.pairing.detail).font(.footnote).foregroundStyle(.secondary)
                if model.supportsOnDeviceHostPairing {
                    Button(.localized("Start on-device pairing"), systemImage: "antenna.radiowaves.left.and.right") {
                        model.startOnDevicePairing()
                    }
                    .disabled(!model.canStartOnDevicePairing)
                    if model.isHostPairing {
                        if let pin = model.hostPairingPIN {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(.localized("Pairing PIN")).font(.caption).foregroundStyle(.secondary)
                                Text(pin).font(.system(.title2, design: .monospaced)).fontWeight(.semibold)
                                Text(.localized("Open Settings > Privacy & Security > Developer Mode and enter this PIN. The PIN is shown only for this active session."))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        Button(.localized("Cancel pairing"), role: .cancel) { model.cancelOnDevicePairing() }
                    }
                }
                Button(model.hasReviewedRecord ? String.localized("Replace pairing record…") : String.localized("Import pairing record…"), systemImage: "square.and.arrow.down") {
                    reviewedFingerprint = model.fingerprint
                    if model.hasReviewedRecord { confirmReplacement = true }
                    else { chooseRecord(replacing: nil) }
                }
                .disabled(!model.canImport)
                Button(.localized("Refresh record"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isWorking)
            } header: {
                Text(.localized("3 · Pair or review a compatible record"))
            } footer: {
                Text(.localized("On supported iOS 27+ devices, VexSign can start an on-device pairing host. You must explicitly start pairing and confirm the PIN in Settings. Only bounded flat pairing plists are accepted. The remote identifier is the host's identity, not this iPhone's UDID. Import preserves original bytes and never converts one format into another. Replacing a record requires confirmation and an unchanged reviewed fingerprint."))
              }

            Section {
                TextField(.localized("VPN peer Device IP (usually 10.7.0.1)"), text: $model.peerAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .disabled(model.isWorking)
                if hasVPNURLHandler {
                    Button(.localized("Open LocalDevVPN"), systemImage: "arrow.up.forward.app") {
                        // Open only. Installation/activation/permission remain the user's action.
                        UIApplication.open("localdevvpn://")
                    }
                } else {
                    Button(.localized("Get LocalDevVPN"), systemImage: "arrow.down.app") {
                        UIApplication.open("https://apps.apple.com/us/app/localdevvpn/id6755608044")
                    }
                }
                Text(.localized("Install and activate a compatible VPN yourself in its own app or Settings. A URL handler, interface address, or reachable TCP port does not prove VPN ownership, pairing trust or installation support. The usual peer is 10.7.0.1/32; 10.7.1.1/32 is this device's interface and is rejected."))
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text(.localized("4 · Explicit local transport setup")) }

            Section {
                Toggle(.localized("Allow experimental local device-service queries"), isOn: $model.consent)
                Text(.localized("This uses community implementations of Apple's device protocols, not a public general-purpose iOS installation API. Approval permits local identity and service queries only; it does not approve account provisioning, key export or installation. No VexSign backend receives the pairing file."))
                    .font(.footnote).foregroundStyle(.secondary)
                TextField(.localized("Intended device UDID"), text: $model.expectedIdentifier)
                    .font(.caption.monospaced()).privacySensitive()
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .disabled(model.isWorking)
                Text(.localized("Check this target against Xcode, Finder or your trusted pairing tool. A record may omit the device UDID; do not substitute its remote host UUID."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(.localized("Verify selected device"), systemImage: "checkmark.shield") { model.verifyDevice() }
                    .disabled(!model.canVerify)
                TextField(.localized("App bundle identifier to read"), text: $model.inventoryBundleIdentifier)
                    .font(.caption.monospaced()).privacySensitive()
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(model.isWorking)
                Button(.localized("Read selected app's installed version"), systemImage: "doc.text.magnifyingglass") {
                    model.readInstalledApplication()
                }
                .disabled(!model.canReadApplication)
                Text(.localized("Experimental read-only CoreDevice metadata. The existing VexSign app identifier is prefilled for a harmless self-query. Missing results do not prove absence; this check cannot unlock installation gates."))
                    .font(.caption).foregroundStyle(.secondary)
                if let summary = model.inventorySummary {
                    Label(summary, systemImage: "doc.text").font(.footnote)
                }
                if model.isWorking {
                    HStack { ProgressView(); Text(model.stageTitle ?? String.localized("Working")) }
                    if model.isQuerying {
                        Button(.localized("Cancel query"), role: .cancel) { model.cancelQuery() }
                    }
                }
                if model.isTransportRetiring {
                    Text(.localized("The native transport is still retiring. A cancelled or timed-out waiter never frees pointers being used by a native call. Wait before retrying; reopen VexSign if the native call never returns."))
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let summary = model.verifiedDeviceSummary {
                    Label(summary, systemImage: "checkmark.shield").font(.footnote)
                }
                if let message = model.message {
                    Text(message).font(.footnote).textSelection(.enabled)
                }
            } header: {
                Text(.localized("5 · Fresh read-only authorization check"))
            } footer: {
                Text(.localized("The 30-second deadline bounds this screen's wait, not the native FFI call. A blocked worker keeps exclusive ownership until it actually retires. New operations are refused, not run concurrently. Unsupported remote routes and simulators remain blocked; on-device host pairing requires a supported device and a fresh verification."))
              }

            Section {
                Text(model.installationLimitation).font(.footnote).foregroundStyle(.orange)
                Text(.localized("Imported paid-certificate signing still uses the existing certificate store and signing engine without Apple Account login. Native account signing remains gated by CMS/security and physical-device evidence. Pairing alone grants neither signing nor installation readiness."))
                    .font(.footnote)
                NavigationLink(destination: CertificatesView()) {
                    Label(.localized("Certificates Manager"), systemImage: "checkmark.seal")
                }
                NavigationLink(destination: SigningMethodsView()) {
                    Label(.localized("Signing Methods"), systemImage: "signature")
                }
            } header: { Text(.localized("6 · Signing and installation gates")) }

            Section {
                Button(.localized("Export reviewed pairing record…"), systemImage: "square.and.arrow.up") {
                    reviewedFingerprint = model.fingerprint
                    confirmExport = true
                }
                .disabled(!model.pairing.isUsable || !model.hasReviewedRecord || model.isWorking)
                Button(.localized("Delete reviewed pairing record…"), role: .destructive) {
                    reviewedFingerprint = model.fingerprint
                    confirmDeletion = true
                }
                .disabled(!model.hasReviewedRecord || model.isWorking)
            } header: {
                Text(.localized("Advanced · same reviewed record lifecycle"))
            } footer: {
                Text(.localized("Pairing exports contain credentials. Share only with a trusted, compatible destination you explicitly select. This is a file handoff, not proof of companion receipt or compatibility. Temporary exports are protected and cleaned on dismissal or later process recovery."))
              }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
            else { model.leaveScreen() }
        }
        .onDisappear { model.leaveScreen() }
        .confirmationDialog(.localized("Replace the active pairing record?"), isPresented: $confirmReplacement, titleVisibility: .visible) {
            Button(.localized("Choose replacement"), role: .destructive) { chooseRecord(replacing: reviewedFingerprint) }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("This replaces the reviewed local host identity only if it is still unchanged. Existing operations must retire first. Invalid input preserves the previous record; no destination or companion record is overwritten silently."))
        }
        .confirmationDialog(.localized("Delete the reviewed pairing record?"), isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button(.localized("Delete local record"), role: .destructive) {
                if let reviewedFingerprint { model.deleteRecord(reviewedFingerprint: reviewedFingerprint) }
            }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("This removes the reviewed local credential, not the device's trust or copies held by other tools. You will need a compatible pairing record for future device queries."))
        }
        .confirmationDialog(.localized("Export private pairing credentials?"), isPresented: $confirmExport, titleVisibility: .visible) {
            Button(.localized("Choose explicit export destination")) {
                if let reviewedFingerprint {
                    model.exportRecord(reviewedFingerprint: reviewedFingerprint) { file in
                        DocumentPicker.export([file]) { model.finishExport(at: file) }
                    }
                }
            }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("The original unmodified plist includes private keys and host identity. Choose a trusted local file destination. VexSign neither converts formats nor verifies receipt by another app. Do not include this file in diagnostics."))
        }
    }

    private func chooseRecord(replacing fingerprint: String?) {
        Presentation.afterDismiss {
            DocumentPicker.open([.xmlPropertyList, .plist, .mobiledevicepairing], asCopy: false, folder: .pairing) { files in
                if let file = files.first { model.importRecord(from: file, replacing: fingerprint) }
            }
        }
    }

    private func refresh() async {
        hasVPNURLHandler = URL(string: "localdevvpn://").map { UIApplication.shared.canOpenURL($0) } ?? false
        await model.refresh()
    }
}
