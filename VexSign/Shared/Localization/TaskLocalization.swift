import Foundation
import NimbleExtensions

extension UnifiedTaskKind {
    var title: String {
		switch self {
		case .download: .localized("Download")
		case .importIPA: .localized("Import")
		case .sign: .localized("Sign")
		case .install: .localized("Install")
		case .update: .localized("Update")
		case .export: .localized("Export")
        case .deviceSetup: .localized("Device setup")
        case .sourceRefresh: .localized("Source refresh")
        case .containerOperation: .localized("Container operation")
		}
	}

    var icon: String {
		switch self {
		case .download: "arrow.down.circle.fill"
		case .importIPA: "square.and.arrow.down.fill"
		case .sign: "signature"
		case .install: "iphone.badge.plus"
		case .update: "arrow.triangle.2.circlepath"
		case .export: "square.and.arrow.up.fill"
        case .deviceSetup: "cable.connector"
        case .sourceRefresh: "arrow.triangle.2.circlepath"
        case .containerOperation: "shippingbox"
		}
	}
}

extension UnifiedTaskPhase {
    var title: String {
		switch self {
        case .inspectingPairing: .localized("Inspecting pairing record")
        case .checkingTransport: .localized("Checking local transport")
        case .discoveringServices: .localized("Opening device services")
        case .queryingDevice: .localized("Querying device authorization")
        case .importing: .localized("Importing")
        case .readyToSign: .localized("Ready to sign")
        case .signed: .localized("Signed")
        case .preparingInstallation: .localized("Preparing installation")
        case .waitingForIOS: .localized("Waiting for iOS confirmation")
        case .verifying: .localized("Verifying installation")
		case .queued: .localized("Queued")
		case .downloading: .localized("Downloading")
		case .extracting: .localized("Extracting")
		case .signing: .localized("Signing")
		case .installing: .localized("Installing")
		case .completed: .localized("Completed")
		case .failed: .localized("Failed")
		case .cancelled: .localized("Cancelled")
        case .interrupted: .localized("Interrupted")
		case .unconfirmed: .localized("Not confirmed")
		case .paused: .localized("Paused")
		}
	}
}

extension TaskRecoveryGuide {
    var detail: String {
        switch self {
        case .download:
            return .localized("Check connectivity, available storage and download conditions. Confirm the source still provides the file before retrying.")
        case .archive:
            return .localized("Download a fresh IPA from a trusted source and check available storage. Unsafe paths, unsupported links or a corrupt archive must be fixed at the source; do not disable archive validation.")
        case .signing:
            return .localized("Review certificate expiry, provisioning-profile scope, entitlements and injected tweaks. Use Activity Logs to identify the failing step before retrying.")
        case .installation:
            return .localized("Review the selected installation method. Local HTTPS needs device trust and connectivity. Paired installation remains gated until supported same-device inventory and exact-version confirmation are available; a record and VPN are not enough. Signing success alone does not prove installation succeeded.")
        case .deviceSetup:
            return .localized("Open Pairing file and VPN setup. Review the OS route, record format and intended device; activate the VPN yourself. A timed-out native call retains the transport until it retires. Never replace credentials or repeat pairing just to hide a dependency limitation.")
        case .general:
            return .localized("Review the recorded failure stage and Activity Logs, then restart the action from its original screen if retry is unavailable.")
        }
    }
}

extension TaskHistorySort {
    var title: String {
        switch self {
        case .latest: return .localized("Latest activity")
        case .oldest: return .localized("Oldest activity")
        case .name: return .localized("App name")
        }
    }
}
