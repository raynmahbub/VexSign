//
//  LibraryRecoveryBanner.swift
//  VexSign
//
//  Shown once, in the session where an unreadable library store was quarantined.
//
//  Quarantine is the right behaviour — it keeps the app usable and preserves the
//  bundles and certificates on disk — but on its own it looks exactly like the
//  app lost everything. This banner is the difference between "the library was
//  rebuilt" and "this app ate my apps".
//

import SwiftUI
import NimbleExtensions

struct LibraryRecoveryBanner: View {
	let notice: LibraryRecoveryNotice
	let onAcknowledge: () -> Void

	@State private var isAcknowledged = false

	private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .short
		return formatter
	}()

    var body: some View {
        if isAcknowledged && !notice.isPersistentStorageUnavailable {
            EmptyView()
        } else {
            banner
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: notice.isPersistentStorageUnavailable
                    ? "exclamationmark.octagon.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.title3)
            .foregroundStyle(notice.isPersistentStorageUnavailable ? .red : .orange)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    notice.isPersistentStorageUnavailable
                        ? .localized("Persistent Storage Unavailable")
                        : .localized("Library Rebuilt")
                )
                .font(.subheadline.weight(.semibold))

                Text(
                    notice.isPersistentStorageUnavailable
                        ? .localized("The library database could not be opened safely. Write operations are disabled to protect your files. Export diagnostics or restart VexSign to retry.")
                        : .localized("The app list could not be opened, so VexSign set it aside and started a new one. Installed files and certificates are still on this device.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: "\(notice.id) · \(Self.dateFormatter.string(from: notice.recoveredAt))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            if !notice.isPersistentStorageUnavailable {
                Button {
                    isAcknowledged = true
                    onAcknowledge()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(.localized("Dismiss"))
            }
        }
        .padding(12)
        .background(
            (notice.isPersistentStorageUnavailable ? Color.red : Color.orange).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }
}
