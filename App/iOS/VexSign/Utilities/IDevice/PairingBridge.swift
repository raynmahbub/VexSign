//
//  PairingBridge.swift
//  VexSign
//
//  Isolates `IDeviceSwift` (`HeartbeatManager`) and `LockdownClient` behind a single
//  utility boundary so SwiftUI views do not import device-transport frameworks directly.
//

import Foundation
import IDeviceSwift
import NimbleExtensions
import OSLog

private let pairingLogger = Logger(subsystem: "com.vexsign", category: "DevicePicker")

enum PairingBridge {
	static var pairingFilePath: String {
		HeartbeatManager.pairingFile()
	}

	static var pairingFileURL: URL {
		URL(fileURLWithPath: pairingFilePath)
	}

	static var hasPairingFile: Bool {
		FileManager.default.fileExists(atPath: pairingFilePath)
	}

	static func inspectPairingRecord() -> DevicePairingState {
		PairingRecordInspector.inspect(fileAt: pairingFileURL)
	}

	static func restartHeartbeat() {
		HeartbeatManager.shared.start(true)
	}

	static func isSocketConnected() -> Bool {
		HeartbeatManager.shared.checkSocketConnection().isConnected
	}
}

// MARK: - IDeviceManager

/// Reads the pairing record and describes the device it names.
///
/// Not a device manager in the sense of owning sessions: the linked `IDevice` binary talks to one
/// device through the pairing record, and this type reads that record.
@MainActor
final class IDeviceManager {
	static let shared = IDeviceManager()

	private init() {}

	/// Returns the path to the pairing file
	private var pairingFilePath: String {
		HeartbeatManager.pairingFile()
	}

	struct Result: Sendable {
		let pairing: DevicePairingState
		let devices: [PairedDeviceRecord]
	}

	/// One record per device, with the pairing state that produced it.
	///
	/// Duplicate records collapse by UDID, so importing the same pairing file twice — or reading
	/// it in two formats — cannot produce two rows for one device.
	func pairedDevices() async -> Result {
		let url = URL(fileURLWithPath: pairingFilePath)
		let pairing = PairingRecordInspector.inspect(fileAt: url)

		guard let udid = pairing.udid else {
			return Result(pairing: pairing, devices: [])
		}

		let info = await queryDeviceInfo()

		// Presence is "found", not "connected": the record is the only evidence available from
		// inside the sandbox, and the capability report says what still has to happen.
		let record = PairedDeviceRecord(
			udid: udid,
			name: info?.name ?? .localized("iOS Device"),
			deviceType: info?.deviceType ?? .localized("iPhone"),
			iosVersion: info?.iosVersion ?? .localized("Unknown"),
			presence: .discovered,
			pairing: pairing,
			trust: info?.trust ?? .unverified
		)

		return Result(pairing: pairing, devices: PairedDeviceRecord.unique([record]))
	}

	/// Device details through `LockdownClient`.
	///
	/// This reads the record and the running system. It does not open a device session, which is
	/// why the answer it returns can never raise trust.
	private func queryDeviceInfo() async -> DeviceInfo? {
		let pairingFileURL = URL(fileURLWithPath: pairingFilePath)
		guard FileManager.default.fileExists(atPath: pairingFilePath) else { return nil }

		do {
			let client = LockdownClient(pairingFileURL: pairingFileURL)
			try await client.connect()
			let info = try await client.getDeviceInfo()
			await client.disconnect()
			return info
		} catch {
			pairingLogger.debug("Failed to query device info: \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}
}
