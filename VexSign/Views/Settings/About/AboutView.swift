//
//  AboutView.swift
//  VexSign
//
//  A compact About screen: identity, version,
//  capabilities, and useful links. Detailed diagnostics stay in Settings.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct AboutView: View {
    private let sourceURL = "https://github.com/raynmahbub/VexSign"
    private let releasesURL = "https://github.com/raynmahbub/VexSign/releases"
    private let licenseURL = "https://github.com/raynmahbub/VexSign/blob/main/LICENSE"

    var body: some View {
        NBList(.localized("About")) {
            Section {
                VStack(spacing: 10) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: Theme.flareShadow, radius: 12, y: 5)

                    Text(Bundle.main.name.isEmpty ? "VexSign" : Bundle.main.name)
                        .font(.title2.weight(.bold))

                    Text(.localized("On-device signing and app management"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Label(.localized("By Rayn Mahbub"), systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(verbatim: "Version \(Bundle.main.version)\(Bundle.main.buildNumber.isEmpty ? "" : " (\(Bundle.main.buildNumber))")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            NBSection(.localized("What VexSign does")) {
                aboutRow("pencil.and.outline", .localized("Sign and install IPAs on-device"))
                aboutRow("bag.fill", .localized("Browse repositories in App Store"))
                aboutRow("folder.fill", .localized("Manage files, tweaks and your library"))
                aboutRow("arrow.down.circle.fill", .localized("Download in the background"))
                aboutRow("lock.shield.fill", .localized("Keep certificates and apps private"))
            }

            NBSection(.localized("Links")) {
                NavigationLink(destination: UpdatesSettingsView()) {
                    Label(.localized("Check for app updates"), systemImage: "arrow.clockwise")
                }
                Button {
                    UIApplication.open(sourceURL)
                } label: {
                    Label(.localized("Source Code"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button {
                    UIApplication.open(releasesURL)
                } label: {
                    Label(.localized("Releases"), systemImage: "arrow.down.app")
                }
                Button {
                    UIApplication.open(licenseURL)
                } label: {
                    Label(.localized("License (GPL-3.0)"), systemImage: "doc.text")
                }
            } footer: {
                Text(.localized("VexSign is free and open source. Third-party license notices are included with the app."))
            }
        }
    }

    @ViewBuilder
    private func aboutRow(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(.primary)
    }
}
