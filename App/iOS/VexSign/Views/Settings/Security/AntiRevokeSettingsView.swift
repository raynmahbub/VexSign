//
//  AntiRevokeSettingsView.swift
//  VexSign — Anti-Revoke & DNS Protection
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct AntiRevokeSettingsView: View {
    @AppStorage("VexSign.useNovaDNSDynamic") private var useNovaDNSDynamic = false
    @ObservedObject private var checker = BatchCertChecker.shared

    @State private var confirmOnlineOCSP = false
    @State private var revocationHosts: [String] = AntiRevokeManager.revocationHosts
    @State private var hasGeneratedProfile: Bool = AntiRevokeManager.shared.profileURL != nil
    @State private var lastRulesUpdated: String? = NovaDNSDynamic.loadCachedRules().lastUpdated

    private let dnsProfiles: [(name: String, subtitle: String, url: String)] = [
        (name: "NextDNS Apple Profile", subtitle: "Custom DoH configuration profile builder", url: "https://apple.nextdns.io"),
        (name: "AdGuard DNS Profile", subtitle: "Encrypted DNS configuration generator", url: "https://adguard-dns.io/en/public-dns.html")
    ]

    var body: some View {
        NBList(.localized("Anti-Revoke & DNS Shield")) {
            statusSection

            dnsProfilesSection

            targetEndpointsSection

            revokeCheckSection
        }
        .onAppear {
            clearLegacyFakePreferences()
            refreshLocalState()
        }
        .confirmationDialog(.localized("Ask Apple about certificate revocation?"), isPresented: $confirmOnlineOCSP, titleVisibility: .visible) {
            Button(.localized("Ask Apple (OCSP)")) {
                Task { await checker.checkAll(online: true) }
            }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("Sends each certificate's public serial number and issuer details to Apple's OCSP responder to check revocation status. Private .p12 keys and passwords never leave your device."))
        }
    }

    private var statusSection: some View {
        NBSection(.localized("DNS Profile Status")) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((hasGeneratedProfile ? Color.green : Color.secondary).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: hasGeneratedProfile ? "doc.badge.gearshape.fill" : "shield.slash.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(hasGeneratedProfile ? Color.green : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(.localized("Local DoH Profile"))
                            .font(.headline)
                        Text(hasGeneratedProfile ? String.localized("GENERATED") : String.localized("NOT BUILT"))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(hasGeneratedProfile ? Color.green : Color.secondary, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Text(
                        hasGeneratedProfile
                            ? String.localized("A .mobileconfig DoH profile is saved. iOS only applies DNS rules after you install it in Settings → VPN & Device Management.")
                            : String.localized("No local DoH profile built yet. Stock iOS cannot block Apple revocation checks inside an app without an installed DNS profile.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            NavigationLink(destination: AntiRevokeView()) {
                Label(.localized("Build DoH Profile & NovaDNS Rules"), systemImage: "shield.lefthalf.filled")
            }

            if let profileURL = AntiRevokeManager.shared.profileURL {
                Button {
                    AntiRevokeManager.shareProfile(profileURL)
                } label: {
                    Label(.localized("Share Generated .mobileconfig Profile"), systemImage: "square.and.arrow.up")
                }
            }

            LabeledContent(
                .localized("NovaDNS Dynamic"),
                value: useNovaDNSDynamic ? String.localized("Enabled") : String.localized("Off (Default)")
            )
        } footer: {
            Text(.localized("VexSign cannot detect from inside the app sandbox whether you installed a DNS profile in iOS Settings, and no DNS rule can restore a certificate Apple already revoked."))
        }
    }

    private var dnsProfilesSection: some View {
        NBSection(.localized("External DNS Generators")) {
            ForEach(dnsProfiles, id: \.name) { item in
                Button {
                    if let url = URL(string: item.url) {
                        UIApplication.open(url)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.doc.fill")
                            .foregroundStyle(Color.userTint)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            Text(item.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "safari")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.userTint)
                    }
                }
                .buttonStyle(.plain)
            }
        } footer: {
            Text(.localized("Opens external DNS profile tools in Safari. Only install configuration profiles from resolvers you trust."))
        }
    }

    private var targetEndpointsSection: some View {
        NBSection(.localized("Apple Revocation Hosts (Profile Targets)")) {
            ForEach(revocationHosts, id: \.self) { domain in
                HStack(spacing: 10) {
                    Circle()
                        .fill(hasGeneratedProfile ? Color.userTint : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(domain)
                        .font(.footnote.monospaced())
                    Spacer()
                    Text(.localized("DoH target"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            if let lastRulesUpdated {
                LabeledContent(.localized("Rule Snapshot"), value: lastRulesUpdated)
                    .font(.caption)
            }
        } footer: {
            Text(.localized("Synced host list from NovaDNSDynamic rules. Filtering only takes effect when your installed DoH server refuses or sinkholes these hosts."))
        }
    }

    private var revokeCheckSection: some View {
        NBSection(.localized("Real Certificate & OCSP Check")) {
            Button {
                Task { await checker.checkAll(online: false) }
            } label: {
                Label(.localized("Verify Local Expiry & Integrity"), systemImage: "checkmark.shield")
            }
            .disabled(checker.isRunning)

            Button {
                confirmOnlineOCSP = true
            } label: {
                HStack {
                    if checker.isRunning {
                        ProgressView()
                            .scaleEffect(0.9)
                            .padding(.trailing, 6)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Color.userTint)
                    }
                    Text(
                        checker.isRunning
                            ? String.localized("Checking %lld of %lld…", arguments: checker.checkedCount, checker.totalCount)
                            : String.localized("Ask Apple (OCSP) — Check Revocation")
                    )
                    .font(.subheadline.weight(.medium))
                }
            }
            .disabled(checker.isRunning)

            if checker.results.isEmpty {
                Text(
                    Storage.shared.getAllCertificates().isEmpty
                        ? String.localized("No certificates installed in VexSign.")
                        : String.localized("Run a check above to inspect installed certificates against local expiry or Apple OCSP.")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                ForEach(checker.results) { result in
                    HStack(spacing: 10) {
                        Image(systemName: result.statusIcon)
                            .foregroundStyle(result.statusColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                                .font(.subheadline.weight(.medium))
                            if !result.detail.isEmpty {
                                Text(result.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(result.statusTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(result.statusColor)
                    }
                    .padding(.vertical, 2)
                }
            }
        } footer: {
            Text(.localized("Uses Apple's Security framework (`SecPolicyCreateRevocation`) via BatchCertChecker. For full per-certificate details and profile capabilities, open Settings → Certificates → Certificate Health."))
        }
    }

    private func refreshLocalState() {
        revocationHosts = AntiRevokeManager.revocationHosts
        hasGeneratedProfile = AntiRevokeManager.shared.profileURL != nil
        lastRulesUpdated = NovaDNSDynamic.loadCachedRules().lastUpdated
    }

    private func clearLegacyFakePreferences() {
        UserDefaults.standard.removeObject(forKey: "VexSign.antirevoke.enabled")
        UserDefaults.standard.removeObject(forKey: "VexSign.antirevoke.offlineBypass")
    }
}
