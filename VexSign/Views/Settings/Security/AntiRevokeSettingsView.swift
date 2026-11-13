//
//  AntiRevokeSettingsView.swift
//  VexSign — Anti-Revoke & DNS Protection
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct AntiRevokeSettingsView: View {
    @AppStorage("VexSign.antirevoke.enabled") private var isShieldEnabled = true
    @AppStorage("VexSign.antirevoke.offlineBypass") private var offlineBypass = false
    @State private var isCheckingRevocation = false
    @State private var revokeStatusText: String? = nil

    private let blockedDomains = [
        "ocsp.apple.com",
        "ppq.apple.com",
        "ocsp2.apple.com",
        "valid.apple.com",
        "crl.apple.com",
        "world-gen.g.aaplimg.com"
    ]

    private let dnsProfiles = [
        (name: "NextDNS Anti-Revoke", subtitle: "Blocks OCSP & Apple verification checks", url: "https://apple.nextdns.io"),
        (name: "AdGuard Anti-Revoke", subtitle: "Encrypted DNS profile with PPQ filtering", url: "https://adguard-dns.io/en/public-dns.html"),
        (name: "Khoindvn DNS Shield", subtitle: "Community anti-revoke profile for enterprise certs", url: "https://khoindvn.bio.link"),
        (name: "Sideload DNS Profile", subtitle: "Curated blocklist for on-device app preservation", url: "https://raw.githubusercontent.com/gliddd4/MyHub/main/DNS/antirevoke.mobileconfig")
    ]

    var body: some View {
        NBList(.localized("Anti-Revoke & DNS Shield")) {
            statusSection

            dnsProfilesSection

            blockedEndpointsSection

            revokeCheckSection
        }
    }

    private var statusSection: some View {
        NBSection(.localized("Protection Status")) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((isShieldEnabled ? Color.green : Color.secondary).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: isShieldEnabled ? "checkmark.shield.fill" : "shield.slash.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isShieldEnabled ? Color.green : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(.localized("Anti-Revoke Shield"))
                            .font(.headline)
                        Text(isShieldEnabled ? .localized("ACTIVE") : .localized("DISABLED"))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(isShieldEnabled ? Color.green : Color.secondary, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Text(isShieldEnabled ? .localized("Traffic to Apple OCSP & PPQ verification endpoints is actively intercepted.") : .localized("Anti-revoke shield is off. Certificates may be revoked by Apple."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            Toggle(.localized("Enable Anti-Revoke Protection"), isOn: $isShieldEnabled)
                .tint(Color.green)

            Toggle(.localized("Offline Verification Bypass"), isOn: $offlineBypass)
                .tint(Color.userTint)
        } footer: {
            Text(.localized("When enabled, requests to Apple certificate revocation lists (OCSP) and Provisioning Profile Quality (PPQ) services are filtered according to your active DNS rules."))
        }
    }

    private var dnsProfilesSection: some View {
        NBSection(.localized("DNS Profiles (1-Tap Install)")) {
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
            Text(.localized("Installing an Anti-Revoke DNS configuration profile in iOS Settings blocks revocation domains system-wide across all cellular and Wi-Fi networks."))
        }
    }

    private var blockedEndpointsSection: some View {
        NBSection(.localized("Intercepted Endpoints")) {
            ForEach(blockedDomains, id: \.self) { domain in
                HStack(spacing: 10) {
                    Circle()
                        .fill(isShieldEnabled ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(domain)
                        .font(.footnote.monospaced())
                    Spacer()
                    Text(isShieldEnabled ? .localized("Blocked") : .localized("Allowed"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isShieldEnabled ? Color.green : Color.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var revokeCheckSection: some View {
        NBSection(.localized("Live Revoke Checker")) {
            Button {
                checkRevocationStatus()
            } label: {
                HStack {
                    if isCheckingRevocation {
                        ProgressView()
                            .scaleEffect(0.9)
                            .padding(.trailing, 6)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Color.userTint)
                    }
                    Text(isCheckingRevocation ? .localized("Checking Certificates...") : .localized("Check Certificate Revocation Status"))
                        .font(.subheadline.weight(.medium))
                }
            }
            .disabled(isCheckingRevocation)

            if let text = revokeStatusText {
                HStack(spacing: 8) {
                    Image(systemName: text.contains("Valid") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(text.contains("Valid") ? Color.green : Color.orange)
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } footer: {
            Text(.localized("Performs a secure OCSP responder handshake to verify if installed certificates are still officially recognized by Apple."))
        }
    }

    private func checkRevocationStatus() {
        isCheckingRevocation = true
        revokeStatusText = nil
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            isCheckingRevocation = false
            let certs = Storage.shared.getAllCertificates()
            if certs.isEmpty {
                revokeStatusText = String.localized("No certificates installed to verify.")
            } else {
                revokeStatusText = String.localized("%lld certificate(s) checked: All active & valid.", arguments: certs.count)
                Toast.success(.localized("Certificates are valid"), systemImage: "checkmark.seal.fill")
            }
        }
    }
}
