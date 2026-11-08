//
//  CertificateFileHandler.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 15.04.2025.
//

import Foundation
import OSLog
import NimbleExtensions

final class CertificateFileHandler: NSObject {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	
	private let _key: URL
	private let _provision: URL
	private let _keyPassword: String?
	private let _certNickname: String?
	private let _isDefault: Bool
	
	private var _certPair: Certificate?
	
	init(
		key: URL,
		provision: URL,
		password: String? = nil,
		nickname: String? = nil,
		isDefault: Bool = false
	) {
		self._key = key
		self._provision = provision
		self._keyPassword = password
		self._certNickname = nickname
		self._isDefault = isDefault
		
		_certPair = CertificateReader(provision).decoded
		
		super.init()
	}
	
	func copy() async throws {
		guard 
			_certPair != nil
		else {
			throw CertificateFileHandlerError.certNotValid
		}
		
		let destinationURL = try await _directory()

		try _fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
		try _fileManager.copyItem(at: _key, to: destinationURL.appendingPathComponent(_key.lastPathComponent))
		try _fileManager.copyItem(at: _provision, to: destinationURL.appendingPathComponent(_provision.lastPathComponent))
        try ProtectedCertificateFiles.protect(destinationURL)
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

	func clean() {
		try? _fileManager.removeItem(at: _fileManager.certificates(_uuid))
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
