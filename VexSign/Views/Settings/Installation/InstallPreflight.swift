//
//  InstallPreflight.swift
//  VexSign
//
//  one place that names the prerequisite for each way VexSign can put an app on a device,
//  and says which one is missing *before* the install fails later with a sentence about sockets.
//
//  The evaluation is pure — inputs in, rows out — so it can be tested without a device, a pairing
//  file or TrollStore. The view layer is the only part that knows how to look for those things.
//

import Foundation
import NimbleExtensions

// MARK: - Model

enum InstallMethodKind: String, CaseIterable, Identifiable, Sendable {
	case server
	case idevice
	case liveContainer
	case export
	case trollstore

	var id: String { rawValue }

	/// Preserve the existing OTA/IDevice preferences. Unknown values must not fall back to OTA.
	static func selected(forStoredValue value: Int) -> Self? {
		switch value {
		case 0: return .server
		case 1: return .idevice
		case 2: return .liveContainer
		default: return nil
		}
	}

	var title: String {
		switch self {
		case .server:	return .localized("Local HTTPS server")
		case .idevice:	return .localized("idevice (pairing file)")
		case .liveContainer: return .localized("Embedded LiveContainer guest")
		case .export:	return .localized("Export or share the IPA")
		case .trollstore: return .localized("TrollStore")
		}
	}
}

enum InstallReadiness: Equatable, Sendable {
	/// Everything this method needs is present.
	case ready
	/// Present, but something specific is missing; the string says what to do about it.
	case missing(String)
	/// The method cannot work on this device at all (TrollStore is not installed).
	case unavailable(String)
	/// The app cannot check this from inside the sandbox; the string says where to look.
	case unknown(String)
}

struct InstallMethodReport: Identifiable, Equatable, Sendable {
	let method: InstallMethodKind
	let readiness: InstallReadiness
	var id: String { method.rawValue }
}

struct InstallPreflightInputs: Equatable, Sendable {
	/// `LocalTLSIdentity.current() != nil` — a certificate has been imported or generated.
	var hasServerCertificate: Bool = false
	/// `HeartbeatManager.pairingFile()` exists on disk.
	var hasPairingFile: Bool = false
	/// A TrollStore URL scheme answered `canOpenURL`.
	var trollStoreDetected: Bool = false
    /// Local identity presence alone does not mean the user trusted its profile.
    var hasTrustedServerCertificate: Bool = false
	/// A process-local runtime, not an external app URL handler.
	var hasEmbeddedRuntime: Bool = false
}

// MARK: - Evaluation

enum InstallPreflight {
	static func report(_ inputs: InstallPreflightInputs) -> [InstallMethodReport] {
		InstallMethodKind.allCases.map { method in
			InstallMethodReport(method: method, readiness: readiness(for: method, inputs))
		}
	}

	static func readiness(for method: InstallMethodKind, _ inputs: InstallPreflightInputs) -> InstallReadiness {
		switch method {
		case .server:
			return inputs.hasServerCertificate
				? (inputs.hasTrustedServerCertificate ? .ready : .unknown(.localized("A local identity exists, but system trust has not been confirmed. Export and install its Root CA profile in Server & SSL, then enable Full Trust in system Settings → General → About → Certificate Trust Settings.")))
				: .missing(.localized("No local server certificate is available. Open Server & SSL to check the device identity, then export and trust its Root CA profile."))

		case .idevice:
			return inputs.hasPairingFile
				? .unknown(.localized("Pairing file found. Device trust, pairing validity and VPN connectivity will be checked when connecting; file presence alone does not prove readiness."))
				: .missing(.localized("No pairing file. Generate one from a computer on the Tunnel screen; the VPN also has to be running."))

		case .liveContainer:
			return inputs.hasEmbeddedRuntime
				? .ready
				: .unavailable(.localized("The embedded LiveContainer runtime is not loaded. Install the experimental combined host IPA and open its bundled VexSign. The ordinary VexSign IPA cannot import a guest into an external container."))

		case .export:
			// Always possible: the file leaves the device and nothing here has to work.
			return .ready

		case .trollstore:
			return inputs.trollStoreDetected
				? .ready
				: .unavailable(.localized("TrollStore is not installed on this device. VexSign never installs it — without it this route does nothing."))
		}
	}

	/// A one-line summary for the row, so the list reads the same way in every state.
	static func summary(for readiness: InstallReadiness) -> String {
		switch readiness {
		case .ready:
			return .localized("Ready")
		case .missing:
			return .localized("Needs setup")
		case .unavailable:
			return .localized("Not available")
		case .unknown:
			return .localized("Unknown")
		}
	}

	/// The explanation under the row: what it needs, and — when something is missing — what to do.
	static func detail(for report: InstallMethodReport) -> String {
		switch report.readiness {
		case .ready:
			switch report.method {
			case .server:
				return .localized("Uses a server on this device and itms-services://. Needs the certificate above and a reachable host.")
			case .idevice:
				return .localized("Writes the app over AFC and asks installd to install it. No certificate, no hosted server.")
			case .liveContainer:
				return .localized("Prepares a local guest import. Finish import and signing in the host; this is not an iOS device installation. Switching sessions requires confirmation.")
			case .export:
				return .localized("Share the signed IPA and install it elsewhere. Nothing on this device has to be working.")
			case .trollstore:
				return .localized("A TrollStore URL handler was detected. VexSign can hand it an IPA; a URL handler alone does not prove TrollStore is installed or that installation will succeed.")
			}
		case .missing(let message), .unavailable(let message), .unknown(let message):
			return message
		}
	}
}
