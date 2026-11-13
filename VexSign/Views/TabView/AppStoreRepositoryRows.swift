//
//  AppStoreRepositoryRows.swift
//  VexSign
//
//  the repository row and its icons used to live at the bottom of `AppStoreView.swift`,
//  a 1,567-line file. They are self-contained views — an `AltSource`, an optional `ASRepository`
//  and nothing from the parent's state — so they moved here unchanged apart from visibility.
//  Splitting is mechanical on purpose: the behaviour is identical, the diff is a move.
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import NukeUI
import CoreData
import AltSourceKit

// MARK: - Subviews & Helpers

struct RepositoryRow: View {
    let source: AltSource
    let repository: ASRepository?
    /// True when the catalog comes from the offline snapshot cache rather
    /// than a fresh load (repository failing/offline, last-known-good shown).
    var isStale: Bool = false

    private var sourceID: String {
        source.identifier ?? source.sourceURL?.absoluteString ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            RepoIcon(source: source, repository: repository)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(source.name ?? .localized("Unknown Source"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if let url = source.sourceURL?.absoluteString {
                    Text(url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let url = source.sourceURL, VexSignAPI.isPremiumSource(url) {
                        Label(.localized("Premium"), systemImage: "crown.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if SourcePreferences.isTrusted(sourceID) {
                        Label(.localized("Trusted"), systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    // evidence, not opinion. "Trusted" above is the user's own toggle; this
                    // is a signature that was checked on the last refresh.
                    if let url = source.sourceURL, let provenance = SourceProvenanceStore.provenance(for: url),
                       let title = provenance.badgeTitle {
                        Label(title, systemImage: provenance.isAcceptable ? "signature" : "xmark.seal.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(provenance.isAcceptable ? Color.teal : Color.red)
                    }
                    // Status is always icon + text, never color alone, so it
                    // stays distinguishable for every kind of color vision.
                    if isStale {
                        Label(.localized("Saved Copy"), systemImage: "clock.badge.exclamationmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                    } else if let error = SourcePreferences.lastError(for: sourceID), !error.isEmpty {
                        Label(.localized("Failing"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    let count = repository?.apps.count ?? source.appsCount
                    Text(verbatim: count == 1 ? .localized("1 app") : String.localized("%lld apps", arguments: count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Text(.localized("VIEW"))
                .font(.caption.weight(.heavy))
                .tracking(0.4)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.userTint, in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .contextMenu {
            if let url = source.sourceURL {
                Button(.localized("Copy URL"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = url.absoluteString
                }
            }
            if let website = repository?.website {
                Button(.localized("Open Website"), systemImage: "safari") {
                    UIApplication.open(website)
                }
            }
            Button(role: .destructive) {
                SourceRemoval.delete([source])
            } label: {
                Label(.localized("Delete"), systemImage: "trash")
            }
        }
    }
}

struct RepoIcon: View {
    let source: AltSource
    let repository: ASRepository?

    var body: some View {
        let url = repository?.iconURL ?? source.iconURL
        if let url {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image("Repositories").resizable().scaledToFill()
                }
            }
            .processors([.resize(width: 104)])
        } else {
            Image("Repositories").resizable().scaledToFill()
        }
    }
}

struct RepoMiniBadge: View {
    let source: AltSource
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(width: 18, height: 18)

            if let url = source.iconURL {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        VexBrandLogo().scaledToFill()
                    }
                }
                .processors([.resize(width: 28), .circle()])
                .frame(width: 14, height: 14)
            } else {
                VexBrandLogo()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .clipShape(Circle())
            }
        }
    }
}

struct AppStoreIconView: View {
    let app: ASRepository.App
    let size: CGFloat

    var body: some View {
        if let url = app.iconURL {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(uiColor: .tertiarySystemFill)
                }
            }
            .processors([.resize(width: size * 2)])
            .frame(width: size, height: size)
        } else {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
        }
    }
}

extension AltSource {
    var appsCount: Int {
        (value(forKey: "apps") as? Set<NSManagedObject>)?.count ?? 0
    }
}
