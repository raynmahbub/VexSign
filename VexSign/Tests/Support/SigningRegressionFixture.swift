import Foundation
@testable import VexSign

/// Generated, non-runnable code and caller-constructed metadata for unit tests.
/// A decoded Certificate here is NOT an authenticated provisioning profile. Only
/// ProvisioningProfileParser.parse may admit actual signing inventory.
enum SigningRegressionFixture {
    static let team = "TESTTEAM00"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let profileUUID = "01234567-89AB-4CDE-8123-0123456789AB"

    static func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    static func profile(pattern: String = SigningRegressionFixture.team + ".com.example.app", team: String = SigningRegressionFixture.team,
                        prefix: String? = nil, grants: [String: Any] = [:],
                        allDevices: Bool = true, devices: [String]? = nil,
                        platform: [String] = ["iOS"], uuid: String = SigningRegressionFixture.profileUUID) throws -> Certificate {
        var entitlements: [String: Any] = ["application-identifier": pattern,
            "com.apple.developer.team-identifier": team, "keychain-access-groups": [(prefix ?? team) + ".*"]]
        entitlements.merge(grants) { _, new in new }
        var value: [String: Any] = ["AppIDName": "Synthetic metadata only", "Name": "Untrusted test metadata",
            "UUID": uuid, "CreationDate": now.addingTimeInterval(-86_400), "ExpirationDate": now.addingTimeInterval(86_400),
            "ApplicationIdentifierPrefix": [prefix ?? team], "Platform": platform, "TeamIdentifier": [team],
            "TeamName": "Unit test", "TimeToLive": 2, "Version": 1, "ProvisionsAllDevices": allDevices,
            "Entitlements": entitlements]
        if let devices { value["ProvisionedDevices"] = devices }
        return try PropertyListDecoder().decode(Certificate.self, from: plist(value))
    }

    static func unsignedProfileData(_ profile: Certificate) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
        return try encoder.encode(profile)
    }

    static func u32(_ value: UInt32, big: Bool = true) -> Data {
        var value = big ? value.bigEndian : value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    static func blob(_ magic: UInt32, payload: Data) -> Data {
        u32(magic) + u32(UInt32(8 + payload.count)) + payload
    }

    static func superblob(_ entries: [(UInt32, Data)]) -> Data {
        var index = Data(), body = Data()
        let header = 12 + entries.count * 8
        for (slot, blob) in entries {
            index += u32(slot) + u32(UInt32(header + body.count)); body += blob
        }
        return u32(0xfade0cc0) + u32(UInt32(header + body.count)) + u32(UInt32(entries.count)) + index + body
    }

    /// Structurally bounded ARM64 image; an XML-only blob is intentionally NOT a
    /// valid fresh code signature. The platform command is real, not an undersized
    /// fake LC_SEGMENT_64 command that a permissive parser happened to overlook.
    static func machO(entitlements: [String: Any]? = nil, fileType: UInt32 = 2,
                      platform: UInt32 = 2, rawBlobs: [(UInt32, Data)]? = nil) throws -> Data {
        let entries = try rawBlobs ?? entitlements.map { [(UInt32(5), blob(0xfade7171, payload: try plist($0)))] }
        let headerSize = 32, versionSize = 24, signSize = entries == nil ? 0 : 16
        var data = Data()
        for word in [0xfeedfacf, 0x0100000c, 0, fileType, entries == nil ? 1 : 2,
                             UInt32(versionSize + signSize), 0, 0,
                             0x32, UInt32(versionSize), platform, 0x00110000, 0, 0] as [UInt32] {
            data += u32(word, big: false)
        }
        if let entries {
            let signature = superblob(entries)
            for word in [0x1d, 16, UInt32(headerSize + versionSize + signSize), UInt32(signature.count)] as [UInt32] {
                data += u32(word, big: false)
            }
            data += signature
        }
        return data
    }

    static func fat(_ images: [Data], wide: Bool = false, big: Bool = true) -> Data {
        func integer(_ value: UInt64, width: Int) -> Data {
            Data((0..<width).map { index in UInt8(truncatingIfNeeded: value >> (8 * (big ? width - index - 1 : index))) })
        }
        let entrySize = wide ? 32 : 20
        let tableEnd = 8 + images.count * entrySize
        var offset = (tableEnd + 7) / 8 * 8, table = Data(), body = Data(repeating: 0, count: offset - tableEnd)
        for image in images {
            table += integer(0x0100000c, width: 4) + integer(0, width: 4)
            table += integer(UInt64(offset), width: wide ? 8 : 4) + integer(UInt64(image.count), width: wide ? 8 : 4)
            table += integer(3, width: 4)
            if wide { table += integer(0, width: 4) }
            body += image
            let padding = (8 - image.count % 8) % 8
            body += Data(repeating: 0, count: padding); offset += image.count + padding
        }
        return integer(wide ? 0xcafebabf : 0xcafebabe, width: 4) + integer(UInt64(images.count), width: 4) + table + body
    }

    @discardableResult
    static func bundle(at url: URL, identifier: String = "com.example.app", signs: Bool = true,
                       fileType: UInt32 = 2, platform: UInt32 = 2) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try plist(["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"])
            .write(to: url.appendingPathComponent("Info.plist"))
        try machO(entitlements: signs ? [:] : nil, fileType: fileType, platform: platform)
            .write(to: url.appendingPathComponent("Fixture"))
        let signature = url.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
        try plist(["files": [:] as [String: Any], "files2": [:] as [String: Any]])
            .write(to: signature.appendingPathComponent("CodeResources"))
        return url
    }
    // OpenSSL-produced public self-signed test fixture. No private key is retained.
    static let certificateDER: Data = Data(base64Encoded: """
        MIIDbTCCAlWgAwIBAgIUTXgca/74BIH3LItr2gNazURWqrMwDQYJKoZIhvcNAQELBQAwRjELMAkGA1UEBhMCQkQxFjAUBgNV
        BAoMDVZleFNpZ24gVGVzdHMxHzAdBgNVBAMMFlZleFNpZ24gRml4dHVyZSBTaWduZXIwHhcNMjYxMDMxMjM0MTQ4WhcNMjcx
        MjA1MjM0MTQ4WjBGMQswCQYDVQQGEwJCRDEWMBQGA1UECgwNVmV4U2lnbiBUZXN0czEfMB0GA1UEAwwWVmV4U2lnbiBGaXh0
        dXJlIFNpZ25lcjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMUsL7EHTxgy2p2lFOKSUGE9YWC+86qWkGckPACB
        +DSTp2RwnNf+MbqX8R/49j+Gs4TnAH4zUj/icTVjqgiSUBLChM5xqWul5QaRo1V0E3jaDRz18A+S1YIAUWVQ3AvDUqE8Bdal
        sCcZqY+O4bKKqPpm+MvOr4pBTxMKECoiAREB++Jh3k0xYBSpXL31kY0JDzRIeByORSQ0bbhBqIaFC/UHZprBA3hWaCQBrRiq
        8J2u2P0jw/Idn9NDIVVu+jUq1r93vv9wkfXUo8ZTBsEDbe96faMKMxsftkxYezupoNGo8Na4XdTgG+mEKwb1N94nc8sh/ZEr
        1sw76wZweyPH6SUCAwEAAaNTMFEwHQYDVR0OBBYEFJWOi/BtAPNDZ2vUwdAdFtGOUZT2MB8GA1UdIwQYMBaAFJWOi/BtAPND
        Z2vUwdAdFtGOUZT2MA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBADyo/f4dCTyr1/Agx7NNo7fxM4me5UMC
        gnJXvgXLq8kJekl9aSJ3aoGpjJUp2ZhmxzEFAOojDxF8sdgo400L0LrCM4qIuRHQYqQcihJNtFPzEe+Fr2bY8ZqS0KDK9GVe
        N577Wxr+kVxfO96n+YnzGdaN8fHbBUKiIbUoMNbk4e0L3OgeWU19mm9xb10PP5FsuT6MQfbcYS6+CWItGyCkKcpVqIDLdryk
        dil9Fh5vmU+h/SX3klxstgGNDA9/mzR3p1smOHgrXL8Xp03X/dMawAIdf0IjNaS0WNMriTQoSM2tem9GxzBtuXG6cFs71Q0T
        aEzTVgX/Z5MvtIEt5jlh/Sg=
        """, options: .ignoreUnknownCharacters) ?? Data()

    // OpenSSL-produced public self-signed test fixture. No private key is retained.
    static let cms: Data = Data(base64Encoded: """
        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
        Sf3/MLgVi9K6KvplCzNgtBHxwgOw+Y2aRxnGbLE=
        """, options: .ignoreUnknownCharacters) ?? Data()

}
