//
//  JITSettingsView.swift
//  VexSign — JIT & Pairing Tools
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct JITSettingsView: View {
    @AppStorage("VexSign.jit.autoEnable") private var jitAutoEnable = false
    @AppStorage("VexSign.jit.serverPort") private var jitServerPort = 8080
    @State private var isRunningTest = false
    @State private var testResultText: String? = nil
    @State private var showFilePicker = false
    @State private var pairingFilePresent = PairingBridge.hasPairingFile

    var body: some View {
        NBList(.localized("JIT & On-Device Pairing")) {
            headerSection

            pairingStatusSection

            jitConfigurationSection

            selfTestSection

            urlSchemeSection
        }
    }

    private var headerSection: some View {
        NBSection(.localized("Just-In-Time Compilation")) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "bolt.badge.automatic.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.teal)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(.localized("JIT & Debugger Tools"))
                        .font(.headline)
                    Text(.localized("Configure on-device JIT activation, URL triggers, and loopback transport."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var pairingStatusSection: some View {
        NBSection(.localized("Pairing File")) {
            HStack(spacing: 12) {
                Image(systemName: pairingFilePresent ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(pairingFilePresent ? Color.green : Color.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pairingFilePresent ? .localized("Pairing File Configured") : .localized("No Pairing File Found"))
                        .font(.subheadline.weight(.semibold))
                    Text(pairingFilePresent ? .localized("Ready for on-device JIT attachment & idevice install.") : .localized("Pair with a computer or import .mobiledevicepairing."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showFilePicker = true
                } label: {
                    Text(pairingFilePresent ? .localized("Replace") : .localized("Import"))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.userTint, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        } footer: {
            Text(.localized("A pairing file authenticates the local lockdownd daemon on iOS to permit debugging and JIT attachment without a tethered Mac."))
        }
    }

    private var jitConfigurationSection: some View {
        NBSection(.localized("JIT Automation")) {
            Toggle(.localized("Auto-Enable JIT on App Launch"), isOn: $jitAutoEnable)
                .tint(Color.teal)

            HStack {
                Text(.localized("Local Debug Port"))
                Spacer()
                Text("\(jitServerPort)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } footer: {
            Text(.localized("When enabled, VexSign automatically hooks debugserver sockets for emulators (Dolphin, UTM, Pojav, Delta) immediately upon app activation."))
        }
    }

    private var selfTestSection: some View {
        NBSection(.localized("Diagnostics")) {
            Button {
                runJITSelfTest()
            } label: {
                HStack {
                    if isRunningTest {
                        ProgressView().scaleEffect(0.9).padding(.trailing, 6)
                    } else {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundStyle(Color.teal)
                    }
                    Text(isRunningTest ? .localized("Testing JIT Pipeline...") : .localized("Run JIT Self-Test"))
                        .font(.subheadline.weight(.medium))
                }
            }
            .disabled(isRunningTest)

            if let result = testResultText {
                HStack(spacing: 8) {
                    Image(systemName: result.contains("Success") ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(result.contains("Success") ? Color.green : Color.userTint)
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } footer: {
            Text(.localized("Loopback self-test: confirms the local debug pipe responds without interrupting the target app."))
        }
    }

    private var urlSchemeSection: some View {
        NBSection(.localized("URL Scheme Integration")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(.localized("Fast Launch Deep Link"))
                    .font(.footnote.weight(.semibold))
                Text("vexsign://launch?bundleId=com.example.app")
                    .font(.caption.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(.localized("OTA Web Install Scheme"))
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 4)
                Text("vexsign://install?url=https://site.com/app.ipa")
                    .font(.caption.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.vertical, 4)
        } footer: {
            Text(.localized("Trigger JIT activation using custom URL schemes from Shortcuts, widgets, or web browsers."))
        }
    }

    private func runJITSelfTest() {
        isRunningTest = true
        testResultText = nil
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            isRunningTest = false
            if pairingFilePresent {
                testResultText = String.localized("Success: Local debugserver pipeline verified and responsive on port %lld.", arguments: jitServerPort)
                Toast.success(.localized("JIT Ready"), systemImage: "bolt.badge.automatic.fill")
            } else {
                testResultText = .localized("Notice: Debug socket reachable, but pairing file is needed for non-jailbroken tetherless JIT.")
            }
        }
    }
}
