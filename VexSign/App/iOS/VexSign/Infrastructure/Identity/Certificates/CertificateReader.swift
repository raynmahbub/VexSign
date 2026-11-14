//
//  CertificateReader.swift
//  VexSign
//
//  Created by VexSign Contributors on 16.04.2025.
//

import UIKit
import OSLog

class CertificateReader: NSObject {
	let file: URL?
	var decoded: Certificate?
	
	init(_ file: URL?) {
		self.file = file
		super.init()
		self.decoded = self._readAndDecode()
	}
	
	private func _readAndDecode() -> Certificate? {
		guard let file = file else { return nil }
		
		do {
			let fileData = try CertificateInputReader.read(file)
            // Management may display an expired profile, but never unauthenticated
            // metadata. The signing resolver uses the parser's strict expiry path.
            return try ProvisioningProfileParser.parse(fileData, allowingExpiredForDisplay: true)
		} catch {
			Logger.misc.error("Error extracting certificate: \(error.localizedDescription)")
			return nil
		}
	}
}
