//
//  LogRedaction.swift
//  VexSign
//
//  Masks what must not reach a log a user can share.
//
//  `FileLogger` writes to `Documents/Logs/vexsign.log`, which is exposed over USB file sharing and
//  through the Web Manager, and it mirrors everything to OSLog. That stream carries engine output,
//  request URLs and header lines verbatim — so a password typed into the signing sheet, or a bearer
//  token sent to a repository, would sit there readable forever.
//
//  The rules are deliberately narrow. A pattern that fires on ordinary text hides the very thing a
//  log is kept for, so nothing here matches a bare word: every rule needs a key, a header name, or
//  a URL's userinfo before it acts.
//

import Foundation

enum LogRedaction {
	/// What replaces a secret. Plain ASCII so it survives every viewer the log is opened in.
	static let marker = "<redacted>"

	/// Credentials, pairing material, hardware identifiers and account data that can be printed
	/// by plists, JSON, Rust `{:#?}`/idevice pretty printers, HTTP headers and Swift `Key = value`
	/// lines. Values of these keys are never useful in a shared diagnostic; the shape of the value
	/// (its presence) is. Longer names come first so the alternation does not stop early.
	private static let sensitiveKeys: [String] = [
		// Imported certificate/session payloads.
		"certificateP12", "certificatePassword", "adiPb", "appleID",
		"anisetteAdiBlob", "anisetteIdentifier", "adi_pb", "cpim", "spim", "ptm", "tk",
		// Pairing and lockdown secrets.
		"private_key", "alt_irk", "altIRK", "HostPrivateKey", "RootPrivateKey", "EscrowBag",
		"HostCertificate", "RootCertificate", "DeviceCertificate", "SystemBUID", "HostID",
		// Serials and hardware identifiers.
		"MLBSerialNumber", "BasebandSerialNumber", "WirelessBoardSerialNumber", "ChipSerialNo",
		"remotepairing_serial_number", "SerialNumber", "UniqueChipID", "DieID", "ECID",
		// Cellular and network identities.
		"InternationalMobileEquipmentIdentity2", "InternationalMobileEquipmentIdentity",
		"MobileEquipmentIdentifier", "InternationalMobileSubscriberIdentity2",
		"InternationalMobileSubscriberIdentity", "IntegratedCircuitCardIdentity2",
		"IntegratedCircuitCardIdentity", "PhoneNumber",
		"BluetoothAddress", "WiFiAddress", "EthernetMacAddress", "EthernetAddress", "WiFiMACAddress",
		// Apple account / anisette headers and Find My state.
		"adsid", "dsid", "GsIdmsToken", "X-Apple-I-MD-RINFO", "X-Apple-I-MD-M", "X-Apple-I-MD",
		"X-Mme-Device-Id", "fm-account-masked", "fm-spkeys",
		// Personal/device names and UDIDs.
		"DeviceName", "UniqueDeviceID", "UDID", "remotepairing_udid",
	]

	private static let sensitiveKeyAlternation: String = sensitiveKeys
		.map { NSRegularExpression.escapedPattern(for: $0) }
		.joined(separator: "|")

	/// Redacts one line. Safe to call twice: the output contains no secret, so the rules have
	/// nothing left to match.
	static func redact(_ message: String) -> String {
		guard !message.isEmpty else { return message }

		var result = message
		for rule in rules {
			result = rule.apply(to: result)
		}
		return result
	}

	// MARK: - Rules

	/// One pattern and its replacement. The initialiser returns nil for a pattern the regex engine
	/// rejects, so a typo cannot crash the app on the first log line — but it must not pass silently
	/// either, which is why every rule is asserted to fire in `LogRedactionTests`.
	private struct Rule {
		let expression: NSRegularExpression
		let template: String

		init?(pattern: String, template: String) {
			guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
			self.expression = expression
			self.template = template
		}

		func apply(to string: String) -> String {
			let range = NSRange(string.startIndex..<string.endIndex, in: string)
			return expression.stringByReplacingMatches(
				in: string,
				options: [],
				range: range,
				withTemplate: template
			)
		}
	}

	/// Ordered: a bearer token is masked as a token before the header rule can eat the word, and
	/// an email is masked before URL userinfo so a credential URL cannot leave a local part behind.
	private static let rules: [Rule] = [
		// PEM blocks and plist pairing-key material can span multiple lines.
		Rule(pattern: "(?s)-----BEGIN (?:[A-Z ]*PRIVATE KEY|CERTIFICATE)-----.*?-----END (?:[A-Z ]*PRIVATE KEY|CERTIFICATE)-----", template: marker),
		Rule(pattern: #"(?is)<key>\s*(?:\#(sensitiveKeyAlternation))\s*</key>\s*<(?:data|string)>.*?</(?:data|string)>"#, template: marker),
		Rule(pattern: "(?im)(\\b(?:set-cookie|cookie)\\s*:\\s*)[^\\r\\n]+", template: "$1\(marker)"),
		// An email address anywhere: keep the domain (useful for support), hide the account.
		Rule(
			pattern: #"(?i)\b([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b"#,
			template: "\(marker)@$2"
		),
		// `Bearer eyJhbGciOi…` on its own (an Authorization header is handled below).
		Rule(
			pattern: "(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]{6,}",
			template: "Bearer \(marker)"
		),
		// `https://user:secret@host/…` — the password, not the URL.
		Rule(
			pattern: "([A-Za-z][A-Za-z0-9+.\\-]*://)([^/\\s:@]+):([^/\\s@]+)@",
			template: "$1\(marker)@"
		),
		// `password=…`, `p12Password: "…"`, `token=…`, `api-key=…`, `secret=…`.
		Rule(
			pattern: "(?i)\\b(password|passwd|p12password|secret|token|api[_-]?key)\\b(\\s*[:=]\\s*)(\"[^\"]*\"|[^\\s,;&]+)",
			template: "$1$2\(marker)"
		),
		// JSON, plist and header `Key: value` / `Key=value` forms for the high-risk keys above.
		Rule(
			pattern: #"(?i)(?<![\w-])("?(?:\#(sensitiveKeyAlternation))"?\s*[:=]\s*)("(?:[^"\\]|\\.)*"|[^\s,;&}\]]+)"#,
			template: "$1\(marker)"
		),
		// Swift/idevice `  Key = value` lines: the value runs to the end of the line.
		Rule(
			pattern: #"(?m)^(\s*)(\b(?:\#(sensitiveKeyAlternation))\b)\s*=\s*.+$"#,
			template: "$1$2 = \(marker)"
		),
		// Old-style 40-hex UDIDs, only where a key names one (a bare hash stays readable).
		Rule(
			pattern: #"(?i)(\b(?:UniqueDeviceID|UDID|remotepairing_udid)\b\s*[:=]\s*"?)[0-9A-Fa-f]{40}\b"#,
			template: "$1\(marker)"
		),
		// Current UDIDs anywhere: 8 hex, a dash, 16 hex.
		Rule(pattern: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"#, template: marker),
		// `Authorization: <anything>` — covers the schemes the bearer rule does not name.
		// The scheme word (`Basic`, `Digest`, …) is part of the header value and the
		// credential follows it, so both have to go: masking only the scheme left the
		// base64 credential standing on the line behind it.
		Rule(
			pattern: "(?i)(\\bauthorization\\b\\s*:\\s*)(?:(?:basic|bearer|digest|negotiate|token)\\s+)?\\S+",
			template: "$1\(marker)"
		)
	].compactMap { $0 }
}
