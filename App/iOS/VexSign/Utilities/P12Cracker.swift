//
//  P12Cracker.swift
//  VexSign
//
//  Recovers passwords for PKCS#12 (.p12) certificate files using generic weak-password
//  candidates, numeric PIN sequences, or a wordlist the user supplies. The built-in list
//  contains only universally weak strings: no credentials published for a third party's
//  certificate, and nothing tied to a named signing service.
//

import Foundation
import Security
import NimbleExtensions

@MainActor
final class P12Cracker: ObservableObject {
	static let shared = P12Cracker()

	@Published private(set) var isRunning = false
	@Published private(set) var progress: Double = 0.0
	@Published private(set) var currentCandidate: String = ""
	@Published private(set) var testedCount: Int = 0
	@Published private(set) var totalCount: Int = 0
	@Published private(set) var foundPassword: String?

	private var _cancelRequested = false

	/// Common passwords observed across signing services, leaks, and enterprise dumps.
	nonisolated static let commonPasswords: [String] = [
		"", // Blank / no password
		// Short PINs / numeric
		"1", "12", "123", "1234", "12345", "123456", "1234567", "12345678",
		"123456789", "1234567890", "0000", "000000", "1111", "111111",
		"666666", "888888", "999999", "123123", "123321", "12344321",
		"00000000", "11111111", "1212", "121212", "654321", "777777",
		"0000000", "112233", "0101", "2024", "2025", "2026", "2027", "2028",
		// Common English passwords
		"password", "Password", "password1", "Password1", "password123",
		"Password123", "admin", "Admin", "root", "Root", "test", "Test",
		"abc123", "Abc123", "qwerty", "Qwerty", "qwerty123", "iloveyou",
		"letmein", "welcome", "monkey", "dragon", "master", "shadow",
		// iOS / Apple-flavored
		"apple", "Apple", "apple123", "Apple123", "ios", "iOS", "iphone",
		"iPhone", "ipad", "iPad", "appleid", "applep12",
		// Signing vocabulary a user would plausibly choose for their own .p12
		"cert", "Cert", "p12", "P12", "sign", "Sign", "signer", "Signer",
		"developer", "Developer", "app", "App",
		// Generic weak strings - the same ones every password-audit wordlist carries
		"123qwe", "qwe123", "qweasd", "a123456", "A123456", "1qaz2wsx", "1q2w3e",
		"123qweasd", "123abc", "abc1234", "p@ssw0rd", "P@ssw0rd", "passw0rd",
		"123abc456", "123Abc", "q1w2e3", "aaa111", "aaa123", "5201314"
		// Deliberately absent: passwords published for certificates issued by third
		// parties. Recovering a user's own .p12 is the point of this tool; carrying a
		// list of other people's shared credentials is not, and shipping one is both a
		// reputational and a legal exposure that has nothing to do with the feature.
	]

	enum Mode: String, CaseIterable, Identifiable {
		case quickDictionary
		case numericPins
		case fullDictionary

		var id: String { rawValue }

		var title: String {
			switch self {
			case .quickDictionary: String.localized("Common Passwords")
			case .numericPins: String.localized("4-Digit PINs (0000-9999)")
			case .fullDictionary: String.localized("Combined Search")
			}
		}

		var count: Int {
			switch self {
			case .quickDictionary: P12Cracker.commonPasswords.count
			case .numericPins: 10000
			case .fullDictionary: P12Cracker.commonPasswords.count + 10000
			}
		}
	}

	/// Checks a single password against PKCS#12 data using Security framework.
	nonisolated static func verify(p12Data: Data, password: String) -> Bool {
		let options: [String: Any] = [
			kSecImportExportPassphrase as String: password
		]
		var rawItems: CFArray?
		let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)
		return status == errSecSuccess
	}

	func cancel() {
		_cancelRequested = true
		isRunning = false
	}

	/// Runs password recovery against a .p12 file.
	func crack(
		p12URL: URL,
		mode: Mode = .fullDictionary,
		customCandidates: [String] = []
	) async -> String? {
		guard let p12Data = try? Data(contentsOf: p12URL) else { return nil }
		return await crack(p12Data: p12Data, mode: mode, customCandidates: customCandidates)
	}

	func crack(
		p12Data: Data,
		mode: Mode = .fullDictionary,
		customCandidates: [String] = []
	) async -> String? {
		isRunning = true
		_cancelRequested = false
		foundPassword = nil
		testedCount = 0

		var candidates: [String] = []

		if !customCandidates.isEmpty {
			candidates.append(contentsOf: customCandidates)
		}

		switch mode {
		case .quickDictionary:
			candidates.append(contentsOf: Self.commonPasswords)
		case .numericPins:
			for i in 0...9999 {
				candidates.append(String(format: "%04d", i))
			}
		case .fullDictionary:
			candidates.append(contentsOf: Self.commonPasswords)
			for i in 0...9999 {
				candidates.append(String(format: "%04d", i))
			}
		}

		// De-duplicate while preserving order
		var seen = Set<String>()
		candidates = candidates.filter { seen.insert($0).inserted }

		totalCount = candidates.count
		progress = 0.0

		let batchSize = 50

		for chunkStart in stride(from: 0, to: candidates.count, by: batchSize) {
			if _cancelRequested {
				isRunning = false
				return nil
			}

			let chunkEnd = min(chunkStart + batchSize, candidates.count)
			let batch = Array(candidates[chunkStart..<chunkEnd])

			// Run this batch off the main actor
			let matched = await Task.detached(priority: .userInitiated) { () -> String? in
				for candidate in batch {
					if Self.verify(p12Data: p12Data, password: candidate) {
						return candidate
					}
				}
				return nil
			}.value

			testedCount = chunkEnd
			progress = Double(chunkEnd) / Double(max(1, candidates.count))
			currentCandidate = batch.last ?? ""

			if let matched {
				foundPassword = matched
				isRunning = false
				return matched
			}

			// Yield briefly so UI remains responsive
			await Task.yield()
		}

		isRunning = false
		return nil
	}
}
