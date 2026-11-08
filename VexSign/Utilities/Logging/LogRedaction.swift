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

	/// Ordered: a bearer token is masked as a token before the header rule can eat the word.
	private static let rules: [Rule] = [
        // PEM blocks and plist pairing-key material can span multiple lines.
        Rule(pattern: "(?s)-----BEGIN (?:[A-Z ]*PRIVATE KEY|CERTIFICATE)-----.*?-----END (?:[A-Z ]*PRIVATE KEY|CERTIFICATE)-----", template: marker),
        Rule(pattern: "(?is)<key>\\s*(?:HostPrivateKey|RootPrivateKey|HostCertificate|RootCertificate|EscrowBag|DeviceCertificate|WiFiMACAddress|SystemBUID|HostID)\\s*</key>\\s*<(?:data|string)>.*?</(?:data|string)>", template: marker),
        Rule(pattern: "(?im)(\\b(?:set-cookie|cookie)\\s*:\\s*)[^\\r\\n]+", template: "$1\(marker)"),
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
