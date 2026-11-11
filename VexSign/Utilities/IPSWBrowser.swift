//
//  IPSWBrowser.swift
//  VexSign
//
//  Browses Apple firmware (IPSW) files through the free ipsw.me catalog and
//  hands the chosen file to the existing download manager. Nothing is flashed —
//  VexSign only fetches the file, the restore itself is Finder/Apple Configurator
//  or a jailbreak tool's job.
//
//  Catalog endpoints (both return JSON):
//      GET https://api.ipsw.me/v4/devices              -> [{name, identifier, ...}]
//      GET https://api.ipsw.me/v4/device/<identifier>  -> {name, identifier, firmwares: [...]}
//

import Foundation
import OSLog
import NimbleExtensions

// MARK: - Models

struct IPSWDevice: Codable, Identifiable, Sendable, Hashable {
	let name: String
	let identifier: String
	let boardconfig: String?
	let platform: String?

	var id: String { identifier }
}

struct IPSWFirmware: Codable, Identifiable, Sendable, Hashable {
	let identifier: String
	let version: String
	let buildid: String
	let filesize: Int64?
	let url: String?
	let releasedate: Date?
	let uploaddate: Date?
	let signed: Bool?

	var id: String { "\(identifier)-\(buildid)" }

	/// Apple stops signing old builds, so only `signed == true` restores today.
	var isStillSigned: Bool { signed ?? false }

	var downloadURL: URL? {
		guard let url, !url.isEmpty else { return nil }
		return URL(string: url)
	}

	var formattedSize: String {
		guard let filesize, filesize > 0 else { return String.localized("Unknown size") }
		return filesize.formattedFileSize
	}

	var filename: String {
		"\(identifier)_\(version)_\(buildid).ipsw"
	}
}

struct IPSWDeviceDetail: Codable, Sendable {
	let name: String
	let identifier: String
	let firmwares: [IPSWFirmware]?
}

// MARK: - Browser

enum IPSWBrowser {
	enum BrowserError: LocalizedError {
		case invalidIdentifier
		case invalidURL
		case decoding(String)
		case transport(String)

		var errorDescription: String? {
			switch self {
			case .invalidIdentifier: String.localized("Pick a device first.")
			case .invalidURL: String.localized("Could not build the firmware catalog URL.")
			case .decoding(let detail): String.localized("Unexpected firmware catalog response: %@", arguments: detail)
			case .transport(let detail): String.localized("Firmware catalog request failed: %@", arguments: detail)
			}
		}
	}

	static let apiBase = "https://api.ipsw.me/v4"

	// MARK: URLs

	static func devicesURL() -> URL? {
		URL(string: "\(apiBase)/devices")
	}

	/// `?type=ipsw` keeps the response to restore images (no OTA/build manifests).
	static func firmwaresURL(for identifier: String) -> URL? {
		let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }

		var components = URLComponents(string: "\(apiBase)/device/\(trimmed)")
		components?.queryItems = [URLQueryItem(name: "type", value: "ipsw")]
		return components?.url
	}

	// MARK: Decoding (split out for tests)

	static func decodeDevices(_ data: Data) throws -> [IPSWDevice] {
		do {
			return try decoder().decode([IPSWDevice].self, from: data)
		} catch {
			throw BrowserError.decoding(error.localizedDescription)
		}
	}

	static func decodeFirmwares(_ data: Data) throws -> [IPSWFirmware] {
		let detail: IPSWDeviceDetail
		do {
			detail = try decoder().decode(IPSWDeviceDetail.self, from: data)
		} catch {
			throw BrowserError.decoding(error.localizedDescription)
		}
		return detail.firmwares ?? []
	}

	private static func decoder() -> JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}

	// MARK: Fetching

	static func fetchDevices(session: URLSession = .shared) async throws -> [IPSWDevice] {
		guard let url = devicesURL() else { throw BrowserError.invalidURL }
		let data = try await _data(from: url, session: session)
		let devices = try decodeDevices(data)
		return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	static func fetchFirmwares(for identifier: String, session: URLSession = .shared) async throws -> [IPSWFirmware] {
		guard let url = firmwaresURL(for: identifier) else { throw BrowserError.invalidIdentifier }
		let data = try await _data(from: url, session: session)
		let firmwares = try decodeFirmwares(data)
		// Newest first: the catalog lists them oldest-first.
		return firmwares.sorted { lhs, rhs in
			if lhs.version == rhs.version { return lhs.buildid > rhs.buildid }
			return _versionCompare(lhs.version, rhs.version)
		}
	}

	private static func _data(from url: URL, session: URLSession) async throws -> Data {
		do {
			let (data, _) = try await session.data(from: url)
			return data
		} catch {
			throw BrowserError.transport(error.localizedDescription)
		}
	}

	/// Numeric-ish version compare so "18.1" sorts above "17.5.2".
	///
	/// Kept as the firmware browser's own name for it, but the ordering itself is `VersionOrder`'s:
	/// a fourth copy of the same compare is a fourth chance to disagree.
	static func _versionCompare(_ lhs: String, _ rhs: String) -> Bool {
		VersionOrder.isNewer(lhs, than: rhs)
	}

	/// `utsname.machine` is the same identifier the catalog uses ("iPhone15,2").
	static func currentDeviceIdentifier() -> String? {
		var system = utsname()
		uname(&system)
		let mirror = Mirror(reflecting: system.machine)
		let identifier = mirror.children.reduce(into: "") { partial, element in
			guard let value = element.value as? Int8, value != 0 else { return }
			partial.append(Character(UnicodeScalar(UInt8(value))))
		}
		let trimmed = identifier.trimmingCharacters(in: .whitespaces)
		return trimmed.isEmpty ? nil : trimmed
	}
}
