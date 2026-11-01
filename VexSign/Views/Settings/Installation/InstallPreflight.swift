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
	case export
	case trollstore

	var id: String { rawValue }

	var title: String {
		switch self {
		case .server:	return .localized("Local HTTPS server")
		case .idevice:	return .localized("idevice (pairing file)")
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
				? .ready
				: .missing(.localized("No server certificate yet. Open the Server section above and add one, or install over idevice instead."))

		case .idevice:
			return inputs.hasPairingFile
				? .ready
				: .missing(.localized("No pairing file. Generate one from a computer on the Tunnel screen; the VPN also has to be running."))

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
			case .export:
				return .localized("Share the signed IPA and install it elsewhere. Nothing on this device has to be working.")
			case .trollstore:
				return .localized("TrollStore is installed. VexSign can hand it an IPA; it does not install TrollStore or use CoreTrust itself.")
			}
		case .missing(let message), .unavailable(let message), .unknown(let message):
			return message
		}
	}
}
