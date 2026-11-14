//
//  LibraryView+UpdatesAndVault.swift
//  VexSign
//
//  Updates Available and Hidden Apps Vault sections for LibraryView.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

extension LibraryView {
    // MARK: - Hidden Apps Vault Section
    var hiddenAppsVaultSection: some View {
        NBSection(.localized("Hidden Apps")) {
            Button {
                NBHaptic.tap(.medium)
                lockManager.authenticateToRevealHidden { _ in }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill((lockManager.isRevealingHiddenApps ? Color.purple : Color.secondary).opacity(0.15))
                            .frame(width: 32, height: 32)
                        Image(systemName: lockManager.isRevealingHiddenApps ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(lockManager.isRevealingHiddenApps ? Color.purple : Color.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(lockManager.isRevealingHiddenApps ? .localized("Hidden Apps Revealed") : .localized("Hidden Apps Vault"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.primary)
                        Text(lockManager.isRevealingHiddenApps ? .localized("Tap to conceal hidden applications") : String.localized("%lld hidden app(s) • Tap to unlock", arguments: hiddenAppsCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: lockManager.isRevealingHiddenApps ? "lock.open.fill" : "lock.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(lockManager.isRevealingHiddenApps ? Color.purple : Color.secondary)
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Updates Available Section (Apps & Quantity)
    var updatesAvailableSection: some View {
        NBSection(
            .localized("Updates Available"),
            secondary: "\(updateChecker.updateCount) " + (updateChecker.updateCount == 1 ? .localized("Update") : .localized("Updates"))
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.userTint.opacity(0.14))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.userTint)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateChecker.updateCount == 1 ? .localized("1 App Update Available") : String.localized("%lld App Updates Available", arguments: updateChecker.updateCount))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("New versions ready from your repositories"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    NavigationLink(destination: UpdatesView()) {
                        Text(.localized("View All"))
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.userTint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)

                Divider().opacity(0.5)

                // Preview apps with available updates
                ForEach(updateChecker.availableUpdates.prefix(3)) { item in
                    HStack(spacing: 10) {
                        AsyncImage(url: item.iconURL) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFit()
                            } else {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.userTint.opacity(0.12))
                                    .overlay(
                                        Image(systemName: "app.fill")
                                            .font(.caption)
                                            .foregroundStyle(Color.userTint)
                                    )
                            }
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(item.installedVersion ?? "1.0")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                Text(item.sourceVersion ?? "1.1")
                                    .foregroundStyle(Color.userTint)
                                    .fontWeight(.semibold)
                                Text("• \(item.sourceName)")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .font(.caption2)
                        }

                        Spacer()

                        if let url = item.downloadURL {
                            Button {
                                _ = downloadManager.startDownload(
                                    from: url,
                                    id: item.app.currentUniqueId,
                                    appName: item.displayName,
                                    appDescription: item.app.localizedDescription
                                )
                                Toast.info(.localized("Download started"), systemImage: "arrow.down.circle")
                            } label: {
                                Text(.localized("UPDATE"))
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.userTint.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.userTint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if updateChecker.availableUpdates.count > 3 {
                    NavigationLink(destination: UpdatesView()) {
                        HStack {
                            Spacer()
                            Text(String.localized("+%lld more pending updates", arguments: updateChecker.availableUpdates.count - 3))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.userTint)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.userTint)
                            Spacer()
                        }
                        .padding(.top, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
