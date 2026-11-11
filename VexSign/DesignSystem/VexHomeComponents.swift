//
//  VexHomeComponents.swift
//  VexSign
//
//  Shared building blocks for the Home dashboard. They use the design tokens
//  and stay deliberately plain SwiftUI so they work on iOS 16 and later.
//

import SwiftUI

// MARK: - Shared pieces

/// Pure readiness rules for the Home getting-started card.
enum VexHomeSetup {
    static func completedSteps(certificates: Int, repositories: Int, apps: Int) -> Int {
        [certificates > 0, repositories > 0, apps > 0].filter { $0 }.count
    }

    static func isComplete(certificates: Int, repositories: Int, apps: Int) -> Bool {
        completedSteps(certificates: certificates, repositories: repositories, apps: apps) == 3
    }
}


/// `startDownload` also returns an untracked placeholder when admission fails.
/// Identity matters: an older row with the same URL or ID is not that placeholder.
enum VexHomeDownloadFeedback {
    static func isTracked(_ result: Download, in downloads: [Download]) -> Bool {
        downloads.contains { $0 === result }
    }
}

/// A quiet, opaque surface. Glass stays on navigation and hero actions only.
struct VexHomeSurface<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.cardWide, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.cardWide, style: .continuous)
                    .stroke(Theme.separator, lineWidth: contrast == .increased ? 1.5 : 0.5)
            }
    }
}

struct VexHomeMark: View {
    var body: some View {
        VexBrandLogo()
            .scaledToFit()
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.mark, style: .continuous))
            .shadow(color: Theme.tint.opacity(0.24), radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}

struct VexSectionTitle: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct VexHeroAction: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let systemImage: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.85)
                .padding(.horizontal, 12)
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(filled ? Theme.tintDeep : Color.white)
                .background(filled ? Color.white : Color.white.opacity(0.14), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(filled ? 0 : 0.30), lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(VexSignFlareButtonStyle())
    }
}

struct VexQuickAction: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(VexSignFlareButtonStyle())
    }
}

struct VexSetupRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(done ? Color(red: 0.36, green: 0.78, blue: 0.58) : Theme.tint)
                    .frame(width: 36, height: 36)
                    .background(
                        (done ? Color(red: 0.36, green: 0.78, blue: 0.58) : Theme.tint).opacity(0.12),
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(done ? .secondary : .primary)
                        .strikethrough(done)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if !done {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
    }
}

struct VexStatusCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let showsProgress: Bool
    let progress: Double

    var body: some View {
        VexHomeSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if showsProgress, progress >= 0 {
                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(tint)
                }
            }
        }
    }
}

struct VexToolRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}
