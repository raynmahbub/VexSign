//
//  DeviceConnectivity.swift
//  VexSign
//
//  What VexSign knows about the device it signs for — and, just as importantly, what it does
//  not know.
//
//  The picker used to answer harder questions than it could support. A pairing file on disk
//  became a device row, `isTrusted` was written as `true` in two places (one of them
//  `?? true` when the query failed), and each row's identity was a fresh `UUID()` that changed
//  on every refresh. Nothing in that chain is evidence: a file is not an authorization, and an
//  identifier that is regenerated per load cannot be used to detect duplicates or to keep
//  selection across a refresh.
//
//  This file supplies the missing vocabulary. Three separate states, because they fail
//  separately and are fixed separately:
//
//  * `DevicePresence` — is a device there, and is it usable right now?
//  * `DevicePairingState` — is the record on disk present, complete and readable?
//  * `DeviceTrust` — has anything actually proved that this device authorized this host?
//
//  Trust starts at `.unknown` and can only be raised by device-side evidence. Nothing in this
//  file raises it: a readable pairing record means the record is readable, not that the device
//  would accept a session. That distinction is the whole point of the type.
//
//  The capability resolver is the same idea applied to operations: one place that says whether
//  a paired install, an OTA install, an inventory read or an uninstall can work, given the
//  states above — instead of each screen deciding for itself from a Bool.
//

import Foundation
import NimbleExtensions

// MARK: - Presence

/// Where a device is in the discovery and connection lifecycle.
///
/// There is no free-running discovery in this build: the linked `IDevice` binary talks to one
/// device at a time, over the pairing record in Settings, and the app cannot observe a cable
/// from inside the sandbox. So `connected` is a claim that needs evidence, and the states that
/// have none are the honest resting place — not `.connected` with a caveat in a comment.
enum DevicePresence: Equatable, Sendable {
	/// Nothing is known to be reachable.
	case disconnected
	/// A pairing record names a device; no session has been opened.
	case discovering
	/// A device was found but nothing has been opened against it yet.
	case discovered
	case connecting
	case connected
	/// The record exists, the device is there, and trust has not been established.
	case pairingRequired
	/// The device answered and refused the host.
	case unauthorized
	/// The device answered, but this build cannot install on it.
	case unsupported
	case reconnecting
	case failed(String)

	/// Only a completed connection may be treated as usable.
	var isUsable: Bool {
		if case .connected = self { return true }
		return false
	}

	var title: String {
		switch self {
		case .disconnected: .localized("Disconnected")
		case .discovering: .localized("Looking for the device…")
		case .discovered: .localized("Device found")
		case .connecting: .localized("Connecting…")
		case .connected: .localized("Connected")
		case .pairingRequired: .localized("Pairing required")
		case .unauthorized: .localized("Not authorized")
		case .unsupported: .localized("Not supported")
		case .reconnecting: .localized("Reconnecting…")
		case .failed: .localized("Connection failed")
		}
	}

	var detail: String {
		switch self {
		case .disconnected:
			.localized("No pairing record and no session. Connect the device, trust this computer, and import the pairing file in Settings → Installation.")
		case .discovering:
			.localized("VexSign can see a pairing record naming this device. It cannot observe the cable from inside the sandbox, so this is not proof the device is reachable right now.")
		case .discovered:
			.localized("The device was found. A session has not been opened against it yet.")
		case .connecting:
			.localized("Opening a session to the device.")
		case .connected:
			.localized("A session to the device succeeded.")
		case .pairingRequired:
			.localized("The device is reachable but has not authorized this host. Unlock it, tap Trust on the device, then reconnect.")
		case .unauthorized:
			.localized("The device refused this host. A pairing that was revoked or reset on the device cannot be repaired by importing the old file again — pair it again.")
		case .unsupported:
			.localized("The device answered but does not accept this installation transport.")
		case .reconnecting:
			.localized("The previous session ended. VexSign is trying once more.")
		case .failed(let reason):
			reason
		}
	}
}

// MARK: - Pairing

/// The state of the pairing record itself, independent of the device it describes.
enum DevicePairingState: Equatable, Sendable {
	/// No file at the configured path.
	case absent
	/// The file exists and cannot be parsed as a property list, or is not a dictionary.
	case unreadable
	/// Larger than any real pairing record; refused before it is parsed.
	case oversized
	/// Parsed, but missing the fields a session needs. Sorted, so the message is stable.
	case incomplete([String])
	/// Complete enough to name a device. `udid` is normalized for comparison.
	case readable(udid: String)

	var udid: String? {
		guard case .readable(let udid) = self else { return nil }
		return udid
	}

	/// Whether a session could be attempted at all. This is not authorization.
	var isUsable: Bool { udid != nil }

	var title: String {
		switch self {
		case .absent: .localized("No pairing record")
		case .unreadable: .localized("Pairing record unreadable")
		case .oversized: .localized("Pairing record too large")
		case .incomplete: .localized("Pairing record incomplete")
		case .readable: .localized("Pairing record found")
		}
	}

	var detail: String {
		switch self {
		case .absent:
			.localized("Import a .mobiledevicepairing file in Settings → Installation → Pairing file, and keep the pairing VPN running.")
		case .unreadable:
			.localized("The pairing file cannot be parsed as a property list. It may be truncated or the wrong file; import the pairing plist again.")
		case .oversized:
			.localized("The pairing file is larger than a real pairing record, so it was not parsed. Import the original file exported by your pairing tool.")
		case .incomplete(let missing):
			String.localized(
				"The pairing record is missing %@. A session cannot start without them; import a complete pairing plist.",
				arguments: missing.joined(separator: ", ")
			)
		case .readable:
			.localized("The file has the fields a session needs. Readability is not authorization: the device still has to accept the session.")
		}
	}
}

/// Whether anything has proved that the device authorized this host.
///
/// Deliberately not a Bool. `true` used to be written wherever a file could be read, which is
/// the difference between "we have a record" and "the device would accept us".
/// Public because `DeviceInfo` is: the trust of a device is part of its description.
public enum DeviceTrust: String, Equatable, Sendable, CaseIterable {
	/// Device-side evidence: a session succeeded, or the device confirmed an operation.
	case verified
	/// A complete pairing record exists; no device has confirmed it.
	case unverified
	/// No record and no evidence.
	case unknown

	var title: String {
		switch self {
		case .verified: .localized("Trusted")
		case .unverified: .localized("Not yet verified")
		case .unknown: .localized("Trust unknown")
		}
	}

	var detail: String {
		switch self {
		case .verified:
			.localized("The device accepted a session from this host.")
		case .unverified:
			.localized("A complete pairing record exists, but nothing has confirmed the device would accept it. That only happens when a session or an install succeeds.")
		case .unknown:
			.localized("There is no pairing record, so nothing can be said about trust.")
		}
	}
}

// MARK: - Record

/// One device, as VexSign can honestly describe it.
struct PairedDeviceRecord: Identifiable, Equatable, Sendable {
	/// Normalized UDID. This is the identity: it survives a refresh, a rename and a re-import.
	let udid: String
	let name: String
	let deviceType: String
	let iosVersion: String
	let presence: DevicePresence
	let pairing: DevicePairingState
	let trust: DeviceTrust

	/// Stable, unlike the `UUID()` the picker used to regenerate per load. Two refreshes that
	/// describe the same device produce the same `id`, so selection and diffing hold.
	var id: String { udid }

	/// What may appear in a log line. UDIDs are 40-character hardware identifiers; support logs
	/// are shared, so only the tail is kept — enough to tell two rows apart, not enough to
	/// identify the device.
	var logSafeIdentifier: String {
		udid.count <= 4 ? "…" : "…\(udid.suffix(4))"
	}

	/// Collapses records that describe the same device.
	///
	/// Later evidence wins (a second read of the same record is more recent), the first
	/// appearance fixes the order, and the comparison is case-insensitive because a UDID's case
	/// is a formatting choice, not part of its identity.
	static func unique(_ records: [PairedDeviceRecord]) -> [PairedDeviceRecord] {
		var order: [String] = []
		var byID: [String: PairedDeviceRecord] = [:]

		for record in records {
			let key = PairingRecordInspector.normalize(record.udid)
			guard !key.isEmpty else { continue }
			if byID[key] == nil { order.append(key) }
			byID[key] = record
		}

		return order.compactMap { byID[$0] }
	}
}

// MARK: - Pairing record inspection

/// Reads the pairing file without trusting it.
///
/// The keys are the ones a `lockdownd` session needs, and the same set the redaction rules in
/// `LogRedaction` already strip from logs. `CertificateManagementService.validatePairingFile` keeps its own stricter
/// import-time rule (`HostID`); this inspection exists so the rest of the app can say *which*
/// part is missing instead of only that the file is there.
enum PairingRecordInspector {
	/// Everything a usable record carries. A record missing any of these cannot start a session.
	static let requiredKeys = [
		"DeviceID",
		"HostID",
		"SystemBUID",
		"HostPrivateKey",
		"HostCertificate",
		"DeviceCertificate",
		"RootCertificate"
	]

	/// Matches the import limit in `CertificateManagementService.installPairingFile(from:)`, so an oversized file is refused the same
	/// way wherever it is read.
	static let maximumSize = 2 * 1024 * 1024

	static func inspect(fileAt url: URL) -> DevicePairingState {
		guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
		guard let data = try? Data(contentsOf: url) else { // try? ok: an unreadable file is the state being reported
			return .unreadable
		}
		return inspect(data)
	}

	static func inspect(_ data: Data) -> DevicePairingState {
		guard !data.isEmpty else { return .unreadable }
		guard data.count <= maximumSize else { return .oversized }
		guard
			let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil), // try? ok: an unparseable record is the state being reported
			let record = plist as? [String: Any]
		else {
			return .unreadable
		}
		return inspect(record)
	}

	static func inspect(_ record: [String: Any]) -> DevicePairingState {
		let missing = requiredKeys.filter { key in
			guard let value = record[key] else { return true }
			switch value {
			case let string as String:
				return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			case let data as Data:
				return data.isEmpty
			default:
				// A key present with an unexpected type is not missing; the session layer will
				// reject it, and claiming it is absent would send the user looking for the wrong
				// thing.
				return false
			}
		}

		guard missing.isEmpty, let raw = record["DeviceID"] as? String else {
			return .incomplete(missing.sorted())
		}

		let udid = normalize(raw)
		guard !udid.isEmpty else { return .incomplete(["DeviceID"]) }
		return .readable(udid: udid)
	}

	/// A UDID's case is a formatting choice. Normalizing here keeps duplicate detection and
	/// comparison working when a record was written in lower case.
	static func normalize(_ raw: String) -> String {
		raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
	}
}

// MARK: - Capability vocabulary

/// The device-side operations VexSign actually has code for.
///
/// Uninstall goes through `DeviceAppRemoval`, over the same session as a paired install.
enum DeviceOperation: String, CaseIterable, Identifiable, Sendable {
	case pairedInstall
	case otaInstall
	case inventoryRead
	case uninstall

	var id: String { rawValue }

	var title: String {
		switch self {
		case .pairedInstall: .localized("Install over the pairing session")
		case .otaInstall: .localized("Install over the local server (OTA)")
		case .inventoryRead: .localized("Read installed apps")
		case .uninstall: .localized("Uninstall")
		}
	}
}

/// Structured support, in the same spirit as the signing capability statuses: more than a Bool,
/// because "needs authorization" and "cannot work here" call for different sentences.
enum DeviceCapabilityStatus: String, CaseIterable, Equatable, Sendable {
	case supported
	case unsupported
	case requiresAuthorization
	case requiresCompanion
	case requiresUserAction
	case temporarilyUnavailable
	case unknown

	var isSupported: Bool { self == .supported }

	var title: String {
		switch self {
		case .supported: .localized("Supported")
		case .unsupported: .localized("Not supported")
		case .requiresAuthorization: .localized("Needs authorization")
		case .requiresCompanion: .localized("Needs the pairing session")
		case .requiresUserAction: .localized("Needs your input")
		case .temporarilyUnavailable: .localized("Temporarily unavailable")
		case .unknown: .localized("Unknown")
		}
	}
}

/// One capability answer plus the reason, so a screen can show the status and the fix.
struct DeviceCapability: Equatable, Sendable {
	let operation: DeviceOperation
	let status: DeviceCapabilityStatus
	let detail: String
}

struct DeviceCapabilityReport: Equatable, Sendable {
	let capabilities: [DeviceCapability]

	func status(for operation: DeviceOperation) -> DeviceCapabilityStatus {
		capabilities.first { $0.operation == operation }?.status ?? .unknown
	}

	func capability(for operation: DeviceOperation) -> DeviceCapability? {
		capabilities.first { $0.operation == operation }
	}

	/// One line per operation, worst first, for the diagnostics log. Nothing here contains a
	/// UDID; the caller adds the redacted identifier if it needs one.
	var logLines: [String] {
		capabilities
			.sorted { $0.status.rawValue < $1.status.rawValue }
			.map { "Device capability (\($0.operation.rawValue)): \($0.status.rawValue) — \($0.detail)" }
	}
}

/// The inputs a capability answer depends on. Everything is a state the app can actually
/// observe; nothing is inferred from the presence of a file.
struct DeviceCapabilityContext: Equatable, Sendable {
	var pairing: DevicePairingState = .absent
	var presence: DevicePresence = .disconnected
	var trust: DeviceTrust = .unknown
	/// The pairing VPN / heartbeat session is running.
	var pairingTransportAvailable = false
	/// The local HTTPS server has a trusted certificate, so OTA can be served.
	var companionAvailable = false
}

enum DeviceCapabilityResolver {
	static func report(_ context: DeviceCapabilityContext) -> DeviceCapabilityReport {
		DeviceCapabilityReport(capabilities: [
			pairedInstall(in: context),
			otaInstall(in: context),
			inventoryRead(in: context),
			uninstall(in: context)
		])
	}

	/// Installation over the pairing session: needs a complete record and the VPN session it
	/// rides on.
	private static func pairedInstall(in context: DeviceCapabilityContext) -> DeviceCapability {
		switch context.pairing {
		case .absent:
			return .init(
				operation: .pairedInstall,
				status: .requiresUserAction,
				detail: .localized("Import a pairing file in Settings → Installation. Without one there is no session to install over.")
			)
		case .unreadable, .oversized:
			return .init(
				operation: .pairedInstall,
				status: .requiresUserAction,
				detail: context.pairing.detail
			)
		case .incomplete:
			return .init(
				operation: .pairedInstall,
				status: .requiresUserAction,
				detail: context.pairing.detail
			)
		case .readable:
			break
		}

		switch context.presence {
		case .unauthorized:
			return .init(
				operation: .pairedInstall,
				status: .requiresAuthorization,
				detail: context.presence.detail
			)
		case .unsupported:
			return .init(
				operation: .pairedInstall,
				status: .unsupported,
				detail: context.presence.detail
			)
		default:
			break
		}

		guard context.pairingTransportAvailable else {
			return .init(
				operation: .pairedInstall,
				status: .requiresCompanion,
				detail: .localized("The pairing record is complete, but the pairing VPN is not running. Start it on the Tunnel screen; the session runs over it.")
			)
		}

		return .init(
			operation: .pairedInstall,
			status: .supported,
			detail: .localized("Installs through the pairing session. VexSign still verifies the result on the device before calling it installed.")
		)
	}

	private static func otaInstall(in context: DeviceCapabilityContext) -> DeviceCapability {
		guard context.companionAvailable else {
			return .init(
				operation: .otaInstall,
				status: .requiresCompanion,
				detail: .localized("Needs the local HTTPS server with a trusted certificate. Open Server & SSL to set it up.")
			)
		}
		return .init(
			operation: .otaInstall,
			status: .supported,
			detail: .localized("Serves the signed IPA from this device and hands it to installd through itms-services.")
		)
	}

	/// The inventory is the running device's own LaunchServices records. No session is involved,
	/// which is why this is supported even with no pairing at all — and why it says nothing
	/// about a second device.
	private static func inventoryRead(in context: DeviceCapabilityContext) -> DeviceCapability {
		.init(
			operation: .inventoryRead,
			status: .supported,
			detail: .localized("Reads this device's installed-app records through LaunchServices. A device-side listing exists in the linked installation service but needs the pairing session, so the local probe stays the evidence used for verification: a filtered lookup is reported as unknown, never as \"not installed\".")
		)
	}

	/// Removal rides the same pairing session as a paired install, so it has the same
	/// prerequisites and reports the same missing one. `DeviceAppRemoval` owns the sequence:
	/// confirm, ask the device, read the device back.
	private static func uninstall(in context: DeviceCapabilityContext) -> DeviceCapability {
		let session = pairedInstall(in: context)
		guard session.status == .supported else {
			return .init(operation: .uninstall, status: session.status, detail: session.detail)
		}
		return .init(
			operation: .uninstall,
			status: .supported,
			detail: .localized("Removes an app through the pairing session after you confirm it, then reads the device back. If the device cannot be read, the removal is reported as requested, not as done.")
		)
	}
}

// MARK: - Device description

/// Device information retrieved through the pairing record and the running system.
///
/// `trust` replaced a `Bool` that was written as `true` wherever a record could be read. A
/// record proves the file exists; only the device can prove it accepts this host.
public struct DeviceInfo: Sendable, Equatable {
	public let udid: String
	public let name: String
	public let deviceType: String
	public let iosVersion: String
	public let buildVersion: String
	public let modelNumber: String
	public let trust: DeviceTrust

	public init(
		udid: String,
		name: String,
		deviceType: String,
		iosVersion: String,
		buildVersion: String,
		modelNumber: String,
		trust: DeviceTrust = .unverified
	) {
		self.udid = udid
		self.name = name
		self.deviceType = deviceType
		self.iosVersion = iosVersion
		self.buildVersion = buildVersion
		self.modelNumber = modelNumber
		self.trust = trust
	}

	public var displayName: String {
		"\(name) (\(deviceType))"
	}

	/// Only a device-confirmed session may report trusted.
	public var isTrusted: Bool { trust == .verified }
}
