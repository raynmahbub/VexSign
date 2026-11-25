// Synthetic format/key fixtures only. Not Apple certificates, device trust,
// account credentials, a transport emulator, or physical acceptance evidence.
import Foundation
import CryptoKit

internal enum PairingRecordTestFixtures {
    static let device = "00008120-001A2B3C4D5E6F70"
    static let otherDevice = "00008120-101A2B3C4D5E6F70"
    static let host = "11111111-2222-3333-4444-555555555555"

    static func classic() -> [String: Any] {
        ["HostID": host, "SystemBUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
         "WiFiMACAddress": "00:11:22:33:44:55", "UDID": device,
         "HostPrivateKey": Data([1, 2]), "RootPrivateKey": Data([3, 4]),
         "HostCertificate": Data([5, 6]), "RootCertificate": Data([7, 8]),
         "DeviceCertificate": Data([9, 10])]
    }

    static func remote() throws -> [String: Any] {
        // Publicly reproducible TEST seed. Never use in a real host/record.
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map { UInt8($0) }))
        return ["identifier": host, "private_key": key.rawRepresentation,
                "public_key": key.publicKey.rawRepresentation]
    }

    static func data(_ record: [String: Any], format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: record, format: format, options: 0)
    }
}
