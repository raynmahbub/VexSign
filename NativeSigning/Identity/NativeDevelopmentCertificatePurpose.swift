import Foundation

public enum NativeDevelopmentCertificateError: Error, Equatable, Sendable {
    case invalidInput, purposeRejected, teamMismatch, trustRejected, positiveRevocationRequired, contextChanged
}

/// Narrow Apple iPhone Developer leaf policy, NOT trust or a signer identity.
/// Reviewed against SecPolicyCreateiPhoneProfileApplicationSigning, selecting
/// development marker .6.1.2 only (never distribution/TestFlight alternatives).
struct NativeDevelopmentCertificatePurpose {
    static let development = Data([0x2a,0x86,0x48,0x86,0xf7,0x63,0x64,6,1,2])
    static let wwdr = Data([0x2a,0x86,0x48,0x86,0xf7,0x63,0x64,6,2,1])
    static let eku = Data([0x55,0x1d,0x25])
    static let keyUsage = Data([0x55,0x1d,0x0f])
    static let basicConstraints = Data([0x55,0x1d,0x13])
    static let codeSigning = Data([0x2b,6,1,5,5,7,3,3])

    struct Fields {
        let subject: Data
        let publicKey: Data
        let extensions: [Data: Data]
    }

    static func requireDevelopment(_ der: Data, teamIdentifier: String) throws {
        do {
            guard teamIdentifier.utf8.count == 10, teamIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { throw NativeDevelopmentCertificateError.invalidInput }
            let certificate = try fields(der)
            guard try organizationalUnit(certificate.subject) == teamIdentifier else { throw NativeDevelopmentCertificateError.teamMismatch }
            guard certificate.extensions[development] == Data([5,0]),
                  certificate.extensions[basicConstraints] == Data([0x30,0]),
                  certificate.extensions[keyUsage] == Data([3,2,7,0x80]),
                  let encodedEKU = certificate.extensions[eku] else { throw NativeDevelopmentCertificateError.purposeRejected }
            let purposes = try NativeProfileDER.one(encodedEKU, tag: 0x30).children(tag: 0x30, limit: 8)
            guard purposes.count == 1, purposes[0].tag == 6, purposes[0].content == codeSigning else { throw NativeDevelopmentCertificateError.purposeRejected }
        } catch {
            if let safe = error as? NativeDevelopmentCertificateError { throw safe }
            throw NativeDevelopmentCertificateError.purposeRejected
        }
    }

    static func requireWWDR(_ der: Data) throws {
        do {
            guard try fields(der).extensions[wwdr] == Data([5,0]) else { throw NativeDevelopmentCertificateError.purposeRejected }
        } catch { throw NativeDevelopmentCertificateError.purposeRejected }
    }

    static func fields(_ der: Data) throws -> Fields {
        guard !der.isEmpty, der.count <= 64 * 1024 else { throw NativeDevelopmentCertificateError.invalidInput }
        let certificate = try NativeProfileDER.one(der, tag: 0x30).children(tag: 0x30, limit: 3)
        guard certificate.count == 3 else { throw NativeDevelopmentCertificateError.purposeRejected }
        let tbs = try certificate[0].children(tag: 0x30, limit: 8)
        // v3, serial, algorithm, issuer, validity, subject, SPKI, extensions.
        // Unique IDs/alternate versions are deliberately outside this subset.
        guard tbs.count == 8, tbs[0].tag == 0xa0, tbs[5].tag == 0x30, tbs[6].tag == 0x30 else { throw NativeDevelopmentCertificateError.purposeRejected }
        let version = try tbs[0].children(tag: 0xa0, limit: 1)
        guard version.count == 1, version[0].tag == 2, version[0].content == Data([2]) else { throw NativeDevelopmentCertificateError.purposeRejected }
        try NativeProfileDER.positiveInteger(tbs[1])
        let wrapper = try tbs[7].children(tag: 0xa3, limit: 1)
        guard wrapper.count == 1 else { throw NativeDevelopmentCertificateError.purposeRejected }
        let values = try wrapper[0].children(tag: 0x30, limit: 64)
        var extensions: [Data: Data] = [:]
        for value in values {
            let parts = try value.children(tag: 0x30, limit: 3)
            guard parts.count == 2 || parts.count == 3, parts[0].tag == 6, !parts[0].content.isEmpty,
                  extensions[parts[0].content] == nil else { throw NativeDevelopmentCertificateError.purposeRejected }
            if parts.count == 3 {
                guard parts[1].tag == 1, parts[1].content == Data([0xff]) else { throw NativeDevelopmentCertificateError.purposeRejected }
            }
            guard let octets = parts.last, octets.tag == 4 else { throw NativeDevelopmentCertificateError.purposeRejected }
            extensions[parts[0].content] = octets.content
        }
        return Fields(subject: tbs[5].encoded, publicKey: tbs[6].encoded, extensions: extensions)
    }

    private static func organizationalUnit(_ der: Data) throws -> String {
        var units: [String] = []
        for rdn in try NativeProfileDER.one(der, tag: 0x30).children(tag: 0x30, limit: 32) {
            for attribute in try rdn.children(tag: 0x31, limit: 8, sorted: true) {
                let pair = try attribute.children(tag: 0x30, limit: 2)
                guard pair.count == 2, pair[0].tag == 6 else { throw NativeDevelopmentCertificateError.purposeRejected }
                if pair[0].content == Data([0x55,4,0x0b]) {
                    guard pair[1].tag == 0x0c || pair[1].tag == 0x13,
                          pair[1].content.count == 10,
                          let value = String(data: pair[1].content, encoding: .ascii) else { throw NativeDevelopmentCertificateError.teamMismatch }
                    units.append(value)
                }
            }
        }
        guard units.count == 1, let unit = units.first else { throw NativeDevelopmentCertificateError.teamMismatch }
        return unit
    }
}
