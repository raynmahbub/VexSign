//
//  Certificate.swift
//  vexsign
//
//  Created by VexSign Contributors on 5/18/24.
//  Copyright (c) 2026 VexSign Team
//

import Foundation

// MARK: - Certificate (Mobileprovision file)
struct Certificate: Codable {
	var AppIDName: String
	var ApplicationIdentifierPrefix: [String]?
	var CreationDate: Date
	var Platform: [String]
	var IsXcodeManaged: Bool?
	var DeveloperCertificates: [Data]?
	var derEncodedProfile: Data?
	var PPQCheck: Bool?
	var Entitlements: [String: AnyCodable]?
	var ExpirationDate: Date
	var Name: String
	var ProvisionsAllDevices: Bool?
	var ProvisionedDevices: [String]?
	var TeamIdentifier: [String]
	var TeamName: String
	var TimeToLive: Int
	var UUID: String
	var Version: Int

	enum CodingKeys: String, CodingKey {
		case AppIDName,
             ApplicationIdentifierPrefix,
             ProvisionsAllDevices,
			 CreationDate,
			 Platform,
			 IsXcodeManaged,
			 DeveloperCertificates,
			 PPQCheck,
			 Entitlements,
			 ExpirationDate,
			 Name,
			 ProvisionedDevices,
			 TeamIdentifier,
			 TeamName,
			 TimeToLive,
			 UUID,
			 Version
		case derEncodedProfile = "DER-Encoded-Profile"
	}
}
