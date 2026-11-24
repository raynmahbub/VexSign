//
//  SelfBuildExportSection.swift
//  VexSign
//
//  "Save this build as an IPA", for the devices that reinstall VexSign without a
//  certificate in the middle: a TrollStore copy, or a move to another device.
//
//  Nothing else in the app can produce this file. The in-place update path needs a
//  *signed* copy in the library (correctly — it replaces the bundle that is
//  running), but a TrollStore device replaces an app without any signature at all,
//  so those users were told to sign a release of VexSign in order to update
//  VexSign. This is the missing first step, not a shortcut past signing.
//

import SwiftUI
import NimbleExtensions

struct SelfBuildExportSection: View {
    @State private var packageTask: Task<Void, Never>?
    @State private var lastExport: URL?

    private var isPackaging: Bool { packageTask != nil }
    private var isTrollStoreCopy: Bool { TrollStoreHandoff.installedByTrollStore() }

    var body: some View {
        if SelfPackageExporter.isAvailable {
            Section {
                if isPackaging {
                    // Packaging copies the whole bundle once and compresses it, so
                    // the row reports that it is working rather than looking dead.
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(.localized("Packaging this build — this takes a minute."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        start()
                    } label: {
                        Label(.localized("Save this build as an IPA"), systemImage: "shippingbox")
                    }
                }
                if let lastExport, !isPackaging {
                    Button {
                        DocumentPicker.export([lastExport])
                    } label: {
                        Label(.localized("Share the packaged IPA"), systemImage: "square.and.arrow.up")
                    }
                    Text(verbatim: lastExport.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(.localized("This build"))
            } footer: {
                Text(installedCopyExplanation)
                    .font(.caption)
            }
        }
    }

    /// The stored copy stays in Documents/Exports, so the explanation names where
    /// it lands and what installing it still requires.
    private var installedCopyExplanation: String {
        isTrollStoreCopy
            ? .localized("This copy was installed by TrollStore, which replaces an app in place without a certificate. Save the IPA and open it in TrollStore to update VexSign itself.")
            : .localized("The IPA is written to Documents/Exports and can be shared from here. Installing it on a device still needs a signing identity that device trusts.")
    }

    private func start() {
        guard packageTask == nil, let directory = SelfPackageExporter.defaultDirectory else { return }
        packageTask = Task { @MainActor in
            defer { packageTask = nil }
            do {
                // `export` is nonisolated async, so its body runs off the main
                // actor without starting detached work of its own.
                let written = try await SelfPackageExporter.export(to: directory)
                lastExport = written
                Toast.success(.localized("This build is packaged"), systemImage: "shippingbox")
            } catch {
                Toast.error(error.localizedDescription, duration: .sticky)
            }
        }
    }
}
