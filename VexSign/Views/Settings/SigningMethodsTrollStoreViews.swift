// MARK: - SigningMethodsTrollStoreViews
/// TrollStore IPA handoff and refresh helper sheets for SigningMethodsView.

import SwiftUI
import UIKit
import NimbleExtensions

struct TrollStoreInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var selectedDownload: Download?
    @State private var installError: String?
    @State private var isInstalling = false

    private var signedDownloads: [Download] {
        downloadManager.downloads.filter { $0.phase == .completed && !$0.onlyArchiving }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "t.square.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)

                Text(.localized("Install via TrollStore"))
                    .font(.title2.weight(.semibold))

                Text(.localized("Select a signed IPA to install permanently via TrollStore. The app must already be signed with a valid certificate."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if signedDownloads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text(.localized("No signed IPAs available"))
                            .font(.headline)
                        Text(.localized("Sign an app first, then return here to install via TrollStore."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(signedDownloads, id: \.id) { download in
                            Button {
                                selectedDownload = download
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(download.fileName)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text(download.appDescription ?? "")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedDownload?.id == download.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }

                if let download = selectedDownload {
                    Button {
                        Task { await installViaTrollStore(download) }
                    } label: {
                        if isInstalling {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text(.localized("Opening TrollStore…"))
                            }
                        } else {
                            Label(String.localized("Open %@ in TrollStore", arguments: download.fileName), systemImage: "t.square.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)

                    Button {
                        share(download)
                    } label: {
                        Label(.localized("Share Signed IPA Instead"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)

                    Text(.localized("TrollStore performs the install itself. VexSign cannot confirm the result — check TrollStore, then launch the app."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let error = installError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle(.localized("TrollStore Install"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func installViaTrollStore(_ download: Download) async {
        isInstalling = true
        installError = nil
        defer { isInstalling = false }

        guard let ipaURL = download.retainedPackageURL ?? download.pendingFileURL,
              FileManager.default.fileExists(atPath: ipaURL.path) else {
            installError = .localized("Signed IPA file not found")
            return
        }

        switch await TrollStoreHandoff.handOff(ipaURL: ipaURL) {
        case .openedUnverified:
            dismiss()
        case .openFailed:
            installError = .localized("iOS refused to open the TrollStore hand-off URL, so nothing was installed.")
        }
    }

    private func share(_ download: Download) {
        guard let ipaURL = download.retainedPackageURL ?? download.pendingFileURL,
              FileManager.default.fileExists(atPath: ipaURL.path) else {
            installError = .localized("Signed IPA file not found")
            return
        }
        UIActivityViewController.show(activityItems: [ipaURL])
    }
}

struct TrollStoreRefreshView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isOpening = false
    @State private var openFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)

                Text(.localized("Refresh All Apps in TrollStore"))
                    .font(.title2.weight(.semibold))

                Text(.localized("VexSign cannot start a refresh for you — TrollStore does not accept a URL command for it. Open TrollStore, then use Refresh All App Registrations there. Only apps TrollStore installed are affected."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task { await openTrollStore() }
                } label: {
                    if isOpening {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(.localized("Opening…"))
                        }
                    } else {
                        Label(.localized("Open TrollStore"), systemImage: "arrow.up.forward.app")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isOpening)

                if openFailed {
                    Text(.localized("iOS did not open the URL. TrollStore may not be installed, or its URL Scheme setting is off."))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle(.localized("TrollStore Refresh"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func openTrollStore() async {
        isOpening = true
        openFailed = false
        defer { isOpening = false }

        guard let url = URL(string: "\(TrollStoreHandoff.scheme)://") else {
            openFailed = true
            return
        }
        let outcome = await TrollStoreHandoff.open(url)
        if outcome == .openFailed {
            openFailed = true
        }
    }
}
