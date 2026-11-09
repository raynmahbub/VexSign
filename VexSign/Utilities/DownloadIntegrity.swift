//
//  DownloadIntegrity.swift
//  VexSign
//
//  Checks a downloaded package against what its source declared.
//
//  AltStore repositories publish a byte count per app (`ASRepository.App.size`) and, increasingly,
//  a hash; VexSign downloaded whatever arrived, computed a SHA-256 for the log, and imported it.
//  A truncated download then failed three steps later — inside the unarchiver — with a message that
//  said nothing about the download.
//
//  This file is pure: it reads the file once, compares what the source promised, and says which
//  promise was broken. Nothing here decides what to do about it; `DownloadManager` does that, and
//  the user can override a mismatch explicitly, once.
//

import Foundation
import AltSourceKit
import NimbleExtensions

enum DownloadIntegrity {
	/// Generous bound shared with archive inspection so one untrusted IPA
	/// cannot consume unbounded temporary storage before its contents are checked.
	static let maximumPackageBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

	static func transferExceedsPackageLimit(expectedBytes: Int64, receivedBytes: Int64) -> Bool {
		(expectedBytes > 0 && expectedBytes > maximumPackageBytes) || receivedBytes > maximumPackageBytes
	}

	static func expectationExceedsPackageLimit(_ expectation: Expectation?) -> Bool {
		guard let expected = expectation?.byteCount else { return false }
		return transferExceedsPackageLimit(expectedBytes: expected, receivedBytes: 0)
	}

	// MARK: Expectation

	/// What the source said the file should be. An empty expectation means "nothing declared", and
	/// a download is never blocked on nothing.
	struct Expectation: Equatable, Sendable {
		/// Size in bytes, as published by the source.
		var byteCount: Int64?
		/// SHA-256 of the package, when a source (or the user) published one.
		var sha256: String?

		var isEmpty: Bool { byteCount == nil && sha256 == nil }

		init(byteCount: Int64? = nil, sha256: String? = nil) {
			self.byteCount = byteCount
			self.sha256 = sha256.map(FileIntegrity.normalize)
		}
	}

	// MARK: Verdict

	enum Failure: Equatable, Sendable {
		/// `actual` is nil when the file could not be read at all.
		case size(expected: Int64, actual: Int64?)
		/// `actual` is nil when the file could not be read to hash it.
		case hash(expected: String, actual: String?)
	}

	enum Verdict: Equatable, Sendable {
		/// The source declared nothing to check.
		case unverified
		/// Everything the source declared matched.
		case verified(checks: Int)
		/// At least one declared fact did not match.
		case mismatch([Failure])
	}

	// MARK: Verify

	static func verify(fileAt url: URL, expectation: Expectation) -> Verdict {
		var failures: [Failure] = []
		var checks = 0

		if let expected = expectation.byteCount {
			checks += 1
			let actual = byteCount(of: url)
			if actual != expected {
				failures.append(.size(expected: expected, actual: actual))
			}
		}

		if let expected = expectation.sha256 {
			checks += 1
			let actual = FileIntegrity.sha256(of: url)
			if actual != expected {
				failures.append(.hash(expected: expected, actual: actual))
			}
		}

		if !failures.isEmpty {
			return .mismatch(failures)
		}
		return checks == 0 ? .unverified : .verified(checks: checks)
	}

	/// Automatic Update All has no interactive override for a source mismatch:
	/// return a failure message so the caller can delete the file and stop before import.
	static func automaticImportFailure(
		fileAt url: URL,
		expectation: Expectation,
		fileName: String
	) -> String? {
		guard case .mismatch(let failures) = verify(fileAt: url, expectation: expectation) else { return nil }
		return describe(failures, fileName: fileName)
	}

	/// The file's size in bytes, or nil when it cannot be read.
	static func byteCount(of url: URL) -> Int64? {
		guard
			let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), // try? ok: an unreadable file is reported as an unreadable size, not swallowed
			let size = attributes[.size] as? NSNumber
		else {
			return nil
		}
		return size.int64Value
	}

	// MARK: Message

	/// What to tell the user. Numbers are printed in full rather than formatted, so the message can
	/// be compared with the source's own listing and with a file manager.
	static func describe(_ failures: [Failure], fileName: String) -> String {
		let lines: [String] = failures.map { failure in
			switch failure {
			case let .size(expected, actual):
				guard let actual else {
					return .localized(
						"%@ could not be read, but the source says it should be %@ bytes.",
						arguments: fileName, String(expected)
					)
				}
				return .localized(
					"%@ is %@ bytes, but the source says it should be %@ bytes.",
					arguments: fileName, String(actual), String(expected)
				)

			case let .hash(expected, actual):
				guard let actual else {
					return .localized(
						"%@ could not be read to check its SHA-256 (%@).",
						arguments: fileName, expected
					)
				}
				return .localized(
					"%@ has SHA-256 %@, not the %@ that was published.",
					arguments: fileName, actual, expected
				)
			}
		}

		return lines.joined(separator: "\n") + "\n\n" + .localized(
			"Nothing was imported. Download it again, or import it anyway if you trust the file."
		)
	}
}

// MARK: - Sources

extension ASRepository.App {
	/// What this app's source declares about the download VexSign is about to start.
	///
	/// `App.size` is the size AltStore sources publish for the current download; a version entry can
	/// carry its own. The format has no hash field yet, so a hash is only checked when a caller (a
	/// manual URL with a published hash, or a future source field) supplies one.
	var downloadIntegrityExpectation: DownloadIntegrity.Expectation {
		let versionBytes = currentAppVersion?.size.map { Int64($0) }
		return DownloadIntegrity.Expectation(byteCount: size ?? versionBytes, sha256: nil)
	}
}
