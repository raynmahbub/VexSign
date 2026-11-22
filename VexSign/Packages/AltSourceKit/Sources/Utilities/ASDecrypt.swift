//
//  ESignKey.swift
//  vexsign
//
//  Created by VexSign Contributors on 20.01.2025.
//

import Foundation

public class ASDecrypt {
	public enum DecryptionError: Error, Equatable {
		case inputTooLarge
		case invalidEnvelope
		case invalidBase64
		case invalidKey
		case invalidUTF8
	}

	private static let _maxInputBytes = 4 * 1024 * 1024
	private let _input: String
	
	public init(input: String) {
		self._input = input
	}
	
	public func extractBase64() -> Data? {
		guard _input.utf8.count <= Self._maxInputBytes else { return nil }
		let pattern = #"source\[([\s\S]*?)\]"#
		
		if let regex = try? NSRegularExpression(pattern: pattern),
		   let match = regex.firstMatch(in: _input, range: NSRange(_input.startIndex..., in: _input)),
		   let range = Range(match.range(at: 1), in: _input) {
			let compact = _input[range].filter { !$0.isWhitespace }
			guard !compact.isEmpty, let decodedData = Data(base64Encoded: compact) else {
				return nil
			}
			return decodedData
		}
		
		return nil
	}
	
	public func decrypt() -> [String]? {
		decrypt(key: esign_key, keyLength: esign_key_len)
	}
	
	public func decrypt(key: [UInt8], keyLength: Int) -> [String]? {
		try? decryptValidated(key: key, keyLength: keyLength)
	}

	public func decryptValidated(key: [UInt8] = esign_key, keyLength: Int? = nil) throws -> [String] {
		guard _input.utf8.count <= Self._maxInputBytes else {
			throw DecryptionError.inputTooLarge
		}
		guard !key.isEmpty else {
			throw DecryptionError.invalidKey
		}
		let effectiveKeyLength = keyLength ?? key.count
		guard effectiveKeyLength > 0, effectiveKeyLength <= key.count else {
			throw DecryptionError.invalidKey
		}

		let pattern = #"source\[([\s\S]*?)\]"#
		guard let regex = try? NSRegularExpression(pattern: pattern),
		      let match = regex.firstMatch(in: _input, range: NSRange(_input.startIndex..., in: _input)),
		      let range = Range(match.range(at: 1), in: _input) else {
			throw DecryptionError.invalidEnvelope
		}

		let compact = _input[range].filter { !$0.isWhitespace }
		guard !compact.isEmpty, let data = Data(base64Encoded: compact) else {
			throw DecryptionError.invalidBase64
		}

		let encryptedBytes = [UInt8](data)
		var decryptedData = Data(capacity: encryptedBytes.count)
		var keyIndex = 0

		for encryptedByte in encryptedBytes {
			let decryptedByte = encryptedByte ^ key[keyIndex]
			decryptedData.append(decryptedByte)
			keyIndex = (keyIndex + 1) % effectiveKeyLength
		}

		guard let decryptedString = String(data: decryptedData, encoding: .utf8) else {
			throw DecryptionError.invalidUTF8
		}
		return decryptedString.components(separatedBy: "\n")
	}
}
