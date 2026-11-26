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
import IDeviceSwift
import NimbleExtensions

// MARK: - Model

struct InstallPreflightInputs: Equatable, Sendable {
	/// `LocalTLSIdentity.current() != nil` — a certificate has been imported or generated.
	var hasServerCertificate: Bool = false
	/// The pairing record at `PairingBridge.pairingFilePath`, inspected rather than assumed.
	///
	/// A Bool could only say "the file is there". A truncated file, a file that is not a plist
	/// and a complete record were the same answer, so the row told the user to start a VPN for a
	/// record that could never carry a session.
	var pairing: DevicePairingState = .absent

	/// Whether any record exists. Kept for call sites that only need presence.
	var hasPairingFile: Bool { pairing != .absent }
	/// A TrollStore URL scheme answered `canOpenURL`.
	var trollStoreDetected: Bool = false
    /// Local identity presence alone does not mean the user trusted its profile.
    var hasTrustedServerCertificate: Bool = false
	/// A process-local runtime, not an external app URL handler.
	var hasEmbeddedRuntime: Bool = false
    var osVersion: DeviceOSVersion = .current
    var pairedInventoryAccepted = InstallationAppProxy.hasAcceptedInventoryBridge
    var onDeviceHostAvailable = PairingHostBridge.isSupported
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
				? (inputs.hasTrustedServerCertificate ? .ready : .missing(.localized("A local identity exists, but system trust has not been confirmed. Export and install its Root CA profile in Server & SSL, then enable Full Trust in system Settings → General → About → Certificate Trust Settings.")))
				: .missing(.localized("No local server certificate is available. Open Server & SSL to check the device identity, then export and trust its Root CA profile."))

		case .idevice:
			switch inputs.pairing {
            case .absent:
                switch DevicePairingRoute.resolve(inputs.osVersion) {
                case .unsupported: return .unavailable(DeviceTransportError.unsupportedOS.localizedDescription)
                case .unknownOS: return .unavailable(DeviceTransportError.unknownOS.localizedDescription)
                case .hostDependencyRequired: return .unavailable(DeviceTransportError.hostUnavailable.localizedDescription)
                case .importedRemoteRequired: return .unavailable(DeviceTransportError.remoteBridgeUnavailable.localizedDescription)
                case .importedClassic:
                    return .missing(.localized("Import a compatible classic pairing record in the Tunnel screen. Activate the VPN, grant explicit device-service consent, and verify the selected device. A record alone does not establish installation readiness."))
                case .onDeviceHostPairing:
                    guard inputs.onDeviceHostAvailable else { return .unavailable(DeviceTransportError.hostUnavailable.localizedDescription) }
                    guard inputs.pairedInventoryAccepted else { return .unavailable(DeviceTransportError.inventoryBridgeUnavailable.localizedDescription) }
                    return .missing(.localized("In the Tunnel screen, explicitly start on-device pairing and confirm the PIN in Settings. Activate the VPN, grant device-service consent, and verify the selected device. Pairing alone does not establish installation readiness."))
                }
			case .unreadable, .oversized, .incomplete:
				// The record cannot start a session, so this is not "unknown readiness" — it is a
				// record that has to be replaced, and the sentence says which part is wrong.
				return .missing(inputs.pairing.detail)
            case .readable, .validated:
                if let format = inputs.pairing.format {
                    do { try PairingRouteAdmission.requireSessionRoute(format: format, version: inputs.osVersion, onDeviceHostAvailable: inputs.onDeviceHostAvailable) }
                    catch { return .unavailable(error.localizedDescription) }
                }
                guard inputs.pairedInventoryAccepted else {
                    return .unavailable(DeviceTransportError.inventoryBridgeUnavailable.localizedDescription)
                }
                return .unknown(.localized("Pairing record found. Explicit consent, device trust and VPN connectivity are checked when connecting; a readable record does not prove the device would accept the session."))
			}

		case .liveContainer:
			return inputs.hasEmbeddedRuntime
				? .ready
				: .unavailable(.localized("The embedded LiveContainer runtime is not loaded. Install the experimental combined host IPA and open its bundled VexSign. The ordinary VexSign IPA cannot import a guest into an external container."))

		case .export:
			// Always possible: the file leaves the device and nothing here has to work.
			return .ready

		case .trollstore:
			// Availability is "TrollStore installed this copy of VexSign", not
			// "TrollStore is on the device": an app cannot tell those apart.
			return inputs.trollStoreDetected
				? .ready
				: .unavailable(.localized("No TrollStore install of VexSign was detected. VexSign never installs TrollStore, and a missing marker does not prove it is absent — share the signed IPA to TrollStore instead."))
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
				return .localized("Uses AFC and Installation Proxy only after all device and exact-version verification gates pass. It does not require a local HTTPS certificate, but the app still needs valid signing and provisioning.")
			case .liveContainer:
				return .localized("Prepares a local guest import. Finish import and signing in the host; this is not an iOS device installation. Switching sessions requires confirmation.")
			case .export:
				return .localized("Share the signed IPA and install it elsewhere. Nothing on this device has to be working.")
			case .trollstore:
				return .localized("VexSign can hand a signed IPA to TrollStore through apple-magnifier://install. TrollStore installs it itself, and VexSign cannot confirm the result.")
			}
		case .missing(let message), .unavailable(let message), .unknown(let message):
			return message
		}
	}
}
