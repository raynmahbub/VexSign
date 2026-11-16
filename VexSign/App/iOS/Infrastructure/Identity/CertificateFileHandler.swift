//
//  CertificateFileHandler.swift
//  VexSign
//
//  Created by VexSign Contributors on 15.04.2025.
//

import Foundation
import OSLog
import NimbleExtensions

final class CertificateFileHandler: NSObject {
    static let p12FileName = "certificate.p12"
    static let profileFileName = "certificate.mobileprovision"

	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
    var certificateUUID: String { _uuid }
	
	private let _keyPassword: String?
	private let _certNickname: String?
	private let _isDefault: Bool
	
	private var _certPair: Certificate?
	
	init(
		password: String? = nil,
		nickname: String? = nil,
		isDefault: Bool = false
	) {
		self._keyPassword = password
		self._certNickname = nickname
		self._isDefault = isDefault
		
		super.init()
	}
	
	func stage(keyData: Data, provisionData: Data) async throws {
		let destinationURL = try await _directory()

		try _fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try ProtectedCertificateFiles.applyProtectionAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700],
            at: destinationURL.path
        )
		let keyURL = destinationURL.appendingPathComponent(Self.p12FileName)
		let profileURL = destinationURL.appendingPathComponent(Self.profileFileName)
		try keyData.write(to: keyURL, options: .atomic)
		try provisionData.write(to: profileURL, options: .atomic)
        try ProtectedCertificateFiles.protect(destinationURL)
        _certPair = CertificateReader(profileURL).decoded
	}
	
	@MainActor
	func addToDatabase() async throws {
		guard let certificate = _certPair else { throw CertificateFileHandlerError.certNotValid }
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			Storage.shared.addCertificate(
				uuid: _uuid,
				password: _keyPassword,
				nickname: _certNickname,
				ppq: certificate.PPQCheck ?? false,
				expiration: certificate.ExpirationDate,
				isDefault: _isDefault
			) { error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
				}
			}
		}
	}

	/// Removes the files this import staged.
	///
	/// The directory holds the staged `.p12` and profile. An import that fails after staging
	/// leaves a private key on disk, and a silent failure here would leave it there with no
	/// record: the row was never written, so nothing else knows the directory exists until a
	/// `Remove Leftovers` pass runs (which is off by default).
	func clean() {
		let directory = _fileManager.certificates(_uuid)
		guard _fileManager.fileExists(atPath: directory.path) else { return }
		do {
			try _fileManager.removeItem(at: directory)
		} catch {
			Logger.misc.error(
				"Could not remove staged certificate files for \(self._uuid); a private key copy remains on disk until Remove Leftovers runs. \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
			)
		}
	}
	
	private func _directory() async throws -> URL {
		_fileManager.certificates(_uuid)
	}
}

enum CertificateFileHandlerError: LocalizedError {
	case certNotValid
	case invalidIdentity

	var errorDescription: String? {
		switch self {
		case .certNotValid:
			return .localized("The provisioning profile is invalid or could not be read.")
		case .invalidIdentity:
			return .localized("Unable to import the certificate. Check the P12 file, provisioning profile, and password.")
		}
	}
}
