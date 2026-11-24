//
//  EmbeddedRuntimeAvailabilityNote.swift
//  VexSign
//
//  Why "Built-in apps" is missing, where the user goes looking for it.
//

import SwiftUI
import NimbleExtensions

/// The explanation behind an unavailable embedded runtime.
///
/// Three screens used to react to `EmbeddedContainerRuntime.isAvailable` in three different ways:
/// the home card was simply not rendered, installation offered two GitHub links, and the
/// companion screen explained the guest layout only. A user on an ordinary install saw a feature
/// vanish with no statement of why, which reads as a bug on their device rather than as a
/// property of the build they installed.
///
/// The text comes from `RuntimeCapabilityReport.Reason.explanation`, so the screen and the
/// diagnostics export cannot disagree about why the operation is unreachable.
struct EmbeddedRuntimeAvailabilityNote: View {
    private var report: RuntimeCapabilityReport { EmbeddedContainerRuntime.capabilityReport }

    /// The guide is a constant string, so it cannot fail to parse; the optional keeps a typo
    /// from becoming a crash on a screen whose whole job is explaining a limitation.
    private let setupGuide = URL(string: "https://github.com/raynmahbub/VexSign/blob/main/README.md#declared-capabilities-and-their-limits")

    var body: some View {
        if !report.isAvailable(.embeddedContainerUI) {
            Section {
                Label(.localized("Built-in apps are not part of this build"), systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                if let explanation = report.reason(for: .embeddedContainerUI)?.explanation {
                    Text(verbatim: explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // A combined build can reach a host that is present but older than
                // this app. Naming the entry points it does not answer is the
                // difference between "update the host" and "something is broken".
                if let diagnosis = EmbeddedContainerRuntime.hostDiagnosis {
                    Text(verbatim: diagnosis)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(.localized("Signing and installation are unaffected: they use the certificate, provisioning profile and transport you already configured."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let setupGuide {
                    Link(.localized("How the combined build works"), destination: setupGuide)
                        .font(.caption)
                }
            } header: {
                Text(.localized("Built-in apps"))
            }
            .accessibilityElement(children: .contain)
        }
    }
}
