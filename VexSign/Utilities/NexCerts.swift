//
//  NexCerts.swift
//  VexSign
//
//  Free certificate catalog imported from NexStore (NovaDev404).
//  Fetches development certificates from the NexCerts API so users can get
//  started signing without bringing their own cert.
//

import Foundation
import NimbleExtensions

enum NexCerts {
	/// The host every file in this catalogue comes from. Shown before anything is downloaded and
	/// asserted by `NexCertsSourceTests`, so the catalogue cannot quietly move somewhere else.
	static let sourceHost = "sideloading.net"

	private static let apiBaseURL = "https://\(sourceHost)/api/certificates"
	private static let listAllURL = URL(string: "\(apiBaseURL)/list/all")!

	/// These files are a few hundred kilobytes. The cap stops a broken or hostile host from
	/// streaming something enormous into memory.
	private static let maxDownloadBytes = 16 * 1024 * 1024

	/// Every download URL is built here so there is a single place to audit.
	static func downloadURLs(for id: Int) -> (p12: URL, provision: URL, password: URL) {
		(
			p12: URL(string: "\(apiBaseURL)/download/\(id)/cert.p12")!,
			provision: URL(string: "\(apiBaseURL)/download/\(id)/cert.mobileprovision")!,
			password: URL(string: "\(apiBaseURL)/download/\(id)/password")!
		)
	}

	struct CatalogItem: Identifiable, Hashable {
		let id: Int
		let name: String
		let certificateType: String
		let status: Status
		let rawStatusText: String
		let validFrom: String
		let validTo: String
		let folderName: String
		fileprivate let order: Int

		var stringID: String {
			"\(id)-\(name)"
		}

		var subtitle: String {
			var components = [certificateType]
			if !validTo.isEmpty {
				components.append(String.localized("Valid To: %@", arguments: validTo))
			}
			return components.joined(separator: " • ")
		}

		var groupingBaseName: String? {
			guard let range = name.range(of: #"\s+\([^()]+\)$"#, options: .regularExpression) else {
				return nil
			}

			let baseName = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
			return baseName.isEmpty ? nil : baseName
		}

		var p12URL: URL {
			NexCerts.downloadURLs(for: id).p12
		}

		var provisionURL: URL {
			NexCerts.downloadURLs(for: id).provision
		}

		var passwordURL: URL {
			NexCerts.downloadURLs(for: id).password
		}
	}

	struct CatalogSection: Identifiable, Hashable {
		let id: String
		let title: String
		let subtitle: String?
		let status: Status
		let certificates: [CatalogItem]

		var isGroup: Bool {
			certificates.count > 1
		}
	}

	enum Status: String, Hashable {
		case signed
		case revoked
		case expired
		case unknown

		init(apiValue: String) {
			let normalizedValue = apiValue.lowercased()
			if normalizedValue.contains("signed") || normalizedValue.contains("✅") {
				self = .signed
			} else if normalizedValue.contains("revoked") || normalizedValue.contains("❌") {
				self = .revoked
			} else {
				self = .unknown
			}
		}

		init(apiValue: String, validTo: String) {
			let normalizedValue = apiValue.lowercased()
			if Self._isExpired(validTo: validTo) {
				self = .expired
			} else if normalizedValue.contains("revoked") || normalizedValue.contains("❌") {
				self = .revoked
			} else if normalizedValue.contains("signed") || normalizedValue.contains("✅") {
				self = .signed
			} else {
				self = .unknown
			}
		}

		private static func _isExpired(validTo: String) -> Bool {
			let dateFormatter = DateFormatter()
			dateFormatter.dateFormat = "yyyy-MM-dd"
			guard let expiryDate = dateFormatter.date(from: validTo) else {
				return false
			}
			return expiryDate < Date()
		}

		var title: String {
			switch self {
			case .signed:
				String.localized("Signed")
			case .revoked:
				String.localized("Revoked")
			case .expired:
				String.localized("Expired")
			case .unknown:
				String.localized("Unknown")
			}
		}

		static func aggregate(_ statuses: [Status]) -> Status {
			if statuses.contains(.signed) {
				return .signed
			}

			if statuses.contains(.revoked) {
				return .revoked
			}

			if statuses.contains(.expired) {
				return .expired
			}

			return .unknown
		}
	}

	enum NexCertsError: LocalizedError {
		case invalidResponse(URL)
		case invalidJSON
		case emptyCatalog
		case invalidPassword
		case downloadTooLarge(URL)

		var errorDescription: String? {
			switch self {
			case .invalidResponse(let url):
				String.localized("Failed to fetch %@.", arguments: url.absoluteString)
			case .invalidJSON:
				String.localized("The community catalogue response could not be parsed.")
			case .emptyCatalog:
				String.localized("The community catalogue did not return any certificates.")
			case .invalidPassword:
				String.localized("The downloaded certificate password is invalid.")
			case .downloadTooLarge(let url):
				String.localized("%@ returned a file larger than this catalogue can contain.", arguments: url.lastPathComponent)
			}
		}
	}
}

// MARK: - Catalog
extension NexCerts {
	static func fetchCatalog() async throws -> [CatalogSection] {
		let entries = try await _fetchCatalogFromAPI()

		guard !entries.isEmpty else {
			throw NexCertsError.emptyCatalog
		}

		return _buildSections(from: entries)
	}

	private static func _fetchCatalogFromAPI() async throws -> [CatalogItem] {
		let data = try await _downloadData(from: listAllURL)

		struct APICertificate: Codable {
			let id: Int
			let name: String
			let status: String
			let valid_from: String
			let valid_to: String
			let folder_name: String
		}

		let apiCertificates: [APICertificate]
		do {
			apiCertificates = try JSONDecoder().decode([APICertificate].self, from: data)
		} catch {
			throw NexCertsError.invalidJSON
		}

		return apiCertificates.enumerated().map { index, cert in
			CatalogItem(
				id: cert.id,
				name: cert.name,
				certificateType: "Development",
				status: Status(apiValue: cert.status, validTo: cert.valid_to),
				rawStatusText: cert.status,
				validFrom: cert.valid_from,
				validTo: cert.valid_to,
				folderName: cert.folder_name,
				order: index
			)
		}
	}

	private static func _buildSections(from entries: [CatalogItem]) -> [CatalogSection] {
		var groupedEntries: [String: [CatalogItem]] = [:]

		for entry in entries {
			guard let baseName = entry.groupingBaseName else {
				continue
			}

			groupedEntries[baseName, default: []].append(entry)
		}

		var renderedGroups = Set<String>()
		var sections: [CatalogSection] = []

		for entry in entries {
			if let baseName = entry.groupingBaseName,
			   let bucket = groupedEntries[baseName],
			   bucket.count > 1 {
				guard renderedGroups.insert(baseName).inserted else {
					continue
				}

				let sortedBucket = bucket.sorted { $0.order < $1.order }
				sections.append(
					CatalogSection(
						id: "group-\(baseName)",
						title: String.localized("%@ - %lld Versions", arguments: baseName, Int64(sortedBucket.count)),
						subtitle: String.localized("%lld versions available", arguments: Int64(sortedBucket.count)),
						status: Status.aggregate(sortedBucket.map(\.status)),
						certificates: sortedBucket
					)
				)
			} else {
				sections.append(
					CatalogSection(
						id: "single-\(entry.stringID)",
						title: entry.name,
						subtitle: entry.subtitle,
						status: entry.status,
						certificates: [entry]
					)
				)
			}
		}

		return sections
	}
}

// MARK: - Import
extension NexCerts {
	static func importCertificate(_ certificate: CatalogItem) async throws {
		let fileManager = FileManager.default
		let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("NexCerts_\(UUID().uuidString)", isDirectory: true)

		try fileManager.createDirectoryIfNeeded(at: temporaryDirectory)

		do {
			async let p12Contents = _downloadData(from: certificate.p12URL)
			async let provisionContents = _downloadData(from: certificate.provisionURL)
			async let passwordContents = _downloadText(from: certificate.passwordURL)

			let p12URL = temporaryDirectory.appendingPathComponent("certificate.p12")
			let provisionURL = temporaryDirectory.appendingPathComponent("certificate.mobileprovision")
			let p12Data = try await p12Contents
			let provisionData = try await provisionContents
			let passwordText = try await passwordContents

			try p12Data.write(to: p12URL, options: .atomic)
			try provisionData.write(to: provisionURL, options: .atomic)

			let password = passwordText.trimmingCharacters(in: .whitespacesAndNewlines)

			guard FR.checkPasswordForCertificate(for: p12URL, with: password, using: provisionURL) else {
				throw NexCertsError.invalidPassword
			}

			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				FR.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: password,
					certificateName: certificate.name
				) { error in
					try? fileManager.removeFileIfNeeded(at: temporaryDirectory)

					if let error = error {
						continuation.resume(throwing: error)
					} else {
						continuation.resume()
					}
				}
			}
		} catch {
			try? fileManager.removeFileIfNeeded(at: temporaryDirectory)
			throw error
		}
	}
}

// MARK: - Acknowledgement
/// Remembers that the user has read what the community catalogue is and who serves it.
///
/// The acknowledged *host* is stored rather than a bare flag, so the catalogue cannot move to
/// another host and keep an acknowledgement the user never gave for it.
enum NexCertsAccess {
	static let acknowledgementKey = "nexCerts.acknowledgedHost"

	static func hasAcknowledged(_ defaults: UserDefaults = .standard) -> Bool {
		defaults.string(forKey: acknowledgementKey) == NexCerts.sourceHost
	}

	static func acknowledge(_ defaults: UserDefaults = .standard) {
		defaults.set(NexCerts.sourceHost, forKey: acknowledgementKey)
	}

	static func revoke(_ defaults: UserDefaults = .standard) {
		defaults.removeObject(forKey: acknowledgementKey)
	}
}

// MARK: - Networking
extension NexCerts {
	private static func _downloadData(from url: URL) async throws -> Data {
		var request = URLRequest(url: url)
		request.timeoutInterval = 30
		request.setValue("VexSign/1.0", forHTTPHeaderField: "User-Agent")

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
			throw NexCertsError.invalidResponse(url)
		}

		// A host that lies about its length can still exceed the cap; the buffer is already
		// allocated by then. Enforcing it during the transfer needs a streaming downloader,
		// which belongs with the download-integrity work, not here.
		let declaredLength = httpResponse.expectedContentLength
		guard declaredLength <= 0 || declaredLength <= Int64(maxDownloadBytes) else {
			throw NexCertsError.downloadTooLarge(url)
		}
		guard data.count <= maxDownloadBytes else {
			throw NexCertsError.downloadTooLarge(url)
		}

		return data
	}

	private static func _downloadText(from url: URL) async throws -> String {
		let data = try await _downloadData(from: url)
		guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
			throw NexCertsError.invalidJSON
		}

		return text
	}
}
