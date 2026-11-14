import Foundation
import NimbleExtensions

extension BackupComponents {
    var title: String {
		switch self {
		case .certificates: .localized("Certificates")
		case .sources: .localized("Sources")
		case .settings: .localized("Settings")
		case .tweaks: .localized("Tweaks")
        case .library: .localized("App Library")
		default: ""
		}
	}

    var icon: String {
		switch self {
		case .certificates: "checkmark.seal"
		case .sources: "globe.desk"
		case .settings: "gear"
		case .tweaks: "wrench.and.screwdriver"
        case .library: "square.stack.3d.up"
		default: "questionmark"
		}
	}
}

extension BackupIntegrity {
    var summary: String {
		let hash = packSHA256.isEmpty ? String.localized("unavailable") : String(packSHA256.prefix(12))
		if certificateEntries == 0 {
			return String.localized("Integrity: no certificates · SHA-256 %@", arguments: hash)
		}
		return String.localized(
			"Integrity: %lld of %lld certificate folders present · SHA-256 %@",
			arguments: Int64(certificateDirectories), Int64(certificateEntries), hash
		)
	}
}

extension BackupRestoreSummary {
    var lines: [String] {
		var result: [String] = []
		for component in BackupComponents.ordered where restored.contains(component) {
			result.append(line(for: component))
		}
		// Only a summary that actually ran the post-restore read can say something was not found.
		// A caller that recorded counts without verifying is not silently accused of failing.
		if hasVerification, unverified > 0 {
			result.append(.localized("%lld restored item(s) could not be verified. Reopen the app and check those components.", arguments: unverified))
		}
		return result
	}

    private func line(for component: BackupComponents) -> String {
		let added = counts(for: component).added
		let skipped = counts(for: component).skipped
		if skipped > 0 {
			return .localized("%@: %lld added, %lld skipped", arguments: component.title, added, skipped)
		}
		return .localized("%@: %lld added", arguments: component.title, added)
	}
}
