//
//  UpdateMatchingSettingsView.swift
//  VexSign — App Update Tracking & Matching Settings
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct UpdateMatchingSettingsView: View {
    @ObservedObject private var updateChecker = AppUpdateChecker.shared
    @ObservedObject private var prefs = UpdateMatchingPreferences.shared
    @State private var isChecking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showResetAlert = false

    var body: some View {
        NBList(.localized("Update Matching")) {
            // 1. Right now available
            rightNowAvailableSection

            // 2. What this finds
            whatThisFindsSection

            // 3. Match by Name
            matchByNameSection

            // 4. Narrow it down
            narrowItDownSection

            // 5. Which version count
            whichVersionCountSection

            // 6. Reset
            resetSection
        }
    }

    // MARK: - 1. Right Now Available
    private var rightNowAvailableSection: some View {
        NBSection(.localized("Right Now Available")) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.userTint.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.userTint)
                        .rotationEffect(.degrees(isChecking && !reduceMotion ? 360 : 0))
                        .animation(
                            isChecking && !reduceMotion
                                ? Animation.linear(duration: 1).repeatForever(autoreverses: false)
                                : .default,
                            value: isChecking
                        )
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(updateChecker.updateCount)")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.userTint)
                        Text(updateChecker.updateCount == 1 ? .localized("App Update Available") : .localized("App Updates Available"))
                            .font(.headline)
                    }

                    Text(updateChecker.updateCount > 0 ? .localized("Ready to download and sign from your active repositories.") : .localized("All installed apps are on the latest detected versions."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    triggerUpdateCheck()
                } label: {
                    if isChecking {
                        ProgressView()
                            .scaleEffect(0.9)
                            .padding(.horizontal, 8)
                    } else {
                        Text(.localized("Check"))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.userTint, in: Capsule())
                            .foregroundStyle(Color.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isChecking)
            }
            .padding(.vertical, 4)
        } footer: {
            Text(.localized("Shows the number of installed applications with higher version numbers available in your repository sources."))
        }
    }

    // MARK: - 2. What This Finds
    private var whatThisFindsSection: some View {
        NBSection(.localized("What This Finds")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.userTint)
                        .font(.title3)
                    Text(.localized("How Update Matching Operates"))
                        .font(.subheadline.weight(.semibold))
                }

                Text(.localized("VexSign indexes every application bundle identifier and display name in your library. When a connected source publishes a newer build number, VexSign flags it for 1-tap update or automated background signing according to the filters configured below."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 3. Match by Name
    private var matchByNameSection: some View {
        NBSection(.localized("Match by Name")) {
            Picker(.localized("Name Matching"), selection: $prefs.nameMatchingMode) {
                ForEach(NameMatchingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)

            Text(prefs.nameMatchingMode.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } footer: {
            Text(.localized("Balanced strips suffixes like “++” or “Pro” for accurate community mod matching."))
        }
    }

    // MARK: - 4. Narrow It Down
    private var narrowItDownSection: some View {
        NBSection(.localized("Narrow It Down")) {
            Toggle(.localized("Same Developer"), isOn: $prefs.sameDeveloper)
                .tint(Color.userTint)

            Toggle(.localized("Same place it came from"), isOn: $prefs.samePlaceItCameFrom)
                .tint(Color.userTint)
        } footer: {
            Text(.localized("Enforce identical author/developer metadata, and only accept updates from the exact repository the app was originally downloaded from."))
        }
    }

    // MARK: - 5. Which Version Count
    private var whichVersionCountSection: some View {
        NBSection(.localized("Which Version Count")) {
            Toggle(.localized("Include Betas"), isOn: $prefs.includeBetas)
                .tint(Color.userTint)

            Toggle(.localized("Include version with no download"), isOn: $prefs.includeNoDownload)
                .tint(Color.userTint)
        } footer: {
            Text(.localized("Choose whether pre-release/beta versions or metadata-only announcements without direct IPA links count toward available updates."))
        }
    }

    // MARK: - 6. Reset to Defaults
    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showResetAlert = true
            } label: {
                HStack {
                    Spacer()
                    Text(.localized("Back to defaults"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
            }
            .alert(.localized("Reset to Defaults?"), isPresented: $showResetAlert) {
                Button(.localized("Reset"), role: .destructive) {
                    prefs.resetToDefaults()
                    Toast.success(.localized("Reset to default settings"), systemImage: "arrow.counterclockwise")
                    triggerUpdateCheck()
                }
                Button(.localized("Cancel"), role: .cancel) {}
            } message: {
                Text(.localized("This will reset all update matching rules, filters, and criteria back to balanced defaults."))
            }
        } footer: {
            Text(.localized("Restores Balanced name matching and default filter criteria."))
        }
    }

    private func triggerUpdateCheck() {
        isChecking = true
        Task {
            await updateChecker.checkNow()
            isChecking = false
            Toast.info(
                updateChecker.updateCount == 1 ? .localized("1 update found") : String.localized("%lld updates found", arguments: updateChecker.updateCount),
                systemImage: "arrow.triangle.2.circlepath"
            )
        }
    }
}
