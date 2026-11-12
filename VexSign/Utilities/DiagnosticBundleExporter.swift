//
//  DiagnosticBundleExporter.swift
//  VexSign
//
//  Packages a comprehensive, sanitized diagnostic bundle (.zip) containing activity logs,
//  system metrics, certificate metadata summaries, and active signing configurations for
//  easy 1-tap bug reporting and debugging without leaking passwords or private keys.
//

import Foundation
import UIKit
import Zip

enum DiagnosticBundleExporter {
	/// Packages the diagnostic bundle into a .zip and returns the file URL.
	@MainActor
	static func createDiagnosticBundle() -> URL? {
		let fm = FileManager.default
		let stamp = _timestamp()
		let bundleName = "VexSign-Diagnostics-\(stamp)"
		let tempDir = fm.uniqueTemporaryDirectory("DiagnosticBundle")
		let stagingDir = tempDir.appendingPathComponent(bundleName)
		let zipURL = tempDir.appendingPathComponent("\(bundleName).zip")

		do {
			try fm.createDirectoryIfNeeded(at: stagingDir)

			// 1. Sanitized Activity Logs
			let rawLogs = SigningLog.shared.exportText(SigningLog.shared.entries)
			let sanitizedLogs = _sanitize(rawLogs)
			try sanitizedLogs.write(
				to: stagingDir.appendingPathComponent("logs.txt"),
				atomically: true,
				encoding: .utf8
			)

			// 2. System and Environment Info
			let envData = _buildEnvironmentJSON()
			try envData.write(to: stagingDir.appendingPathComponent("environment.json"))

			// 3. Certificates Metadata Summary (No private keys or passwords!)
			let certsData = _buildCertificatesSummaryJSON()
			try certsData.write(to: stagingDir.appendingPathComponent("certificates_summary.json"))

			// 4. Signing Options Summary
			let optionsData = _buildOptionsSummaryJSON()
			try optionsData.write(to: stagingDir.appendingPathComponent("signing_options.json"))

			// 5. Compress into ZIP
			let filesToZip = try fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
			try Zip.zipFiles(paths: filesToZip, zipFilePath: zipURL, password: nil, progress: nil)

			// Clean up staging folder
			try? fm.removeItem(at: stagingDir) // try? ok: best-effort cleanup; temp directory will be cleaned on next launch

			return zipURL
		} catch {
			return nil
		}
	}

	// MARK: - Sanitization

	/// Masks passwords, secret tokens, private keys, and authorization headers.
	static func _sanitize(_ text: String) -> String {
		var result = text

		// Redact password values
		let passwordRegex = try? NSRegularExpression( // try? ok: invalid pattern falls through to no redaction
			pattern: #"(password["':\s=]+)([^"'\s,\r\n]+)"#,
			options: [.caseInsensitive]
		)
		if let passwordRegex {
			let range = NSRange(result.startIndex..., in: result)
			result = passwordRegex.stringByReplacingMatches(
				in: result,
				options: [],
				range: range,
				withTemplate: "$1[REDACTED]"
			)
		}

		// Redact Bearer / API tokens
		let tokenRegex = try? NSRegularExpression( // try? ok: invalid pattern falls through to no redaction
			pattern: #"(Bearer\s+)[A-Za-z0-9_\-\.]{10,}"#,
			options: [.caseInsensitive]
		)
		if let tokenRegex {
			let range = NSRange(result.startIndex..., in: result)
			result = tokenRegex.stringByReplacingMatches(
				in: result,
				options: [],
				range: range,
				withTemplate: "$1[REDACTED_TOKEN]"
			)
		}

		// Redact raw private key blocks if any
		if result.contains("-----BEGIN") {
			let keyRegex = try? NSRegularExpression( // try? ok: invalid pattern falls through to no redaction
				pattern: #"-----BEGIN[A-Z\s]+KEY-----[\s\S]*?-----END[A-Z\s]+KEY-----"#,
				options: []
			)
			if let keyRegex {
				let range = NSRange(result.startIndex..., in: result)
				result = keyRegex.stringByReplacingMatches(
					in: result,
					options: [],
					range: range,
					withTemplate: "[REDACTED_PRIVATE_KEY_BLOCK]"
				)
			}
		}

		return result
	}

	// MARK: - Builders

	private static func _buildEnvironmentJSON() -> Data {
		var diskFree: Int64 = 0
		var diskTotal: Int64 = 0
		if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) { // try? ok: filesystem attrs may be unavailable
			diskFree = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
			diskTotal = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
		}

		let info: [String: Any] = [
			"appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
			"appBuild": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
			"systemName": UIDevice.current.systemName,
			"systemVersion": UIDevice.current.systemVersion,
			"model": UIDevice.current.model,
			"diskFreeBytes": diskFree,
			"diskTotalBytes": diskTotal,
			"isLowPowerModeEnabled": ProcessInfo.processInfo.isLowPowerModeEnabled,
			"activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount,
			"physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
			"locale": Locale.current.identifier,
			"timeZone": TimeZone.current.identifier,
			"timestamp": ISO8601DateFormatter().string(from: Date())
		]

		return (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted])) ?? Data() // try? ok: serialization failure yields empty data
	}

	@MainActor
	private static func _buildCertificatesSummaryJSON() -> Data {
		let certs = Storage.shared.getAllCertificates()
		var summaries: [[String: Any]] = []

		for cert in certs {
			let prov = Storage.shared.getProvisionFileDecoded(for: cert)
			let item: [String: Any] = [
				"nickname": cert.nickname ?? "Unnamed",
				"teamName": prov?.TeamName ?? "Unknown",
				"teamID": prov?.TeamIdentifier.first ?? "Unknown",
				"hasPasswordConfigured": !(cert.signingPassword ?? "").isEmpty,
				"provisionExpiration": prov?.ExpirationDate.description ?? "Unknown",
				"isRevoked": cert.revoked,
				"creationDate": cert.date?.description ?? "Unknown"
			]
			summaries.append(item)
		}

		let result: [String: Any] = [
			"certificateCount": certs.count,
			"certificates": summaries
		]

		return (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])) ?? Data() // try? ok: serialization failure yields empty data
	}

	private static func _buildOptionsSummaryJSON() -> Data {
		let opts = OptionsManager.shared.options
		let summary: [String: Any] = [
			"signingOption": opts.signingOption.rawValue,
			"injectPath": opts.injectPath.rawValue,
			"injectFolder": opts.injectFolder.rawValue,
			"ppqProtection": opts.ppqProtection.rawValue,
			"dynamicProtection": opts.dynamicProtection,
			"fileSharing": opts.fileSharing,
			"itunesFileSharing": opts.itunesFileSharing,
			"proMotion": opts.proMotion,
			"gameMode": opts.gameMode,
			"keychainIsolation": opts.keychainIsolation,
			"enableJIT": opts.enableJIT,
			"fixFilePicker": opts.fixFilePicker,
			"removeAppExtensions": opts.removeAppExtensions,
			"autoRemoveUnsupportedExtensions": opts.autoRemoveUnsupportedExtensions,
			"experiment_replaceSubstrateWithEllekit": opts.experiment_replaceSubstrateWithEllekit,
			"experiment_supportLiquidGlass": opts.experiment_supportLiquidGlass
		]

		return (try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted])) ?? Data() // try? ok: serialization failure yields empty data
	}

	private static func _timestamp() -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		return formatter.string(from: Date())
	}
}
