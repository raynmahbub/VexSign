import Foundation
import CoreFoundation

/// Independent canonical DER writer for the FOUR generated main-app claims,
/// never a generic untrusted ASN.1/plist encoder. Exact XML source binding plus
/// DER byte equality prevent dual-slot semantic drift or BER true encodings.
struct NativeOutputEntitlements {
    static func verify(xmlBlob: Data, derBlob: Data, expectedXML: Data,
                       applicationIdentifier: String, teamIdentifier: String) throws {
        try Task.checkCancellation()
        guard !expectedXML.isEmpty, expectedXML.count <= 64 * 1024,
              expectedXML.starts(with: Data("<?xml".utf8)) else { throw NativeSignedOutputError.unsupportedClaims }
        let expected = try canonicalDER(applicationIdentifier: applicationIdentifier, teamIdentifier: teamIdentifier)
        let dictionary: [String: Any]
        do { dictionary = try NativeMainAppAcceptance.dictionary(expectedXML) }
        catch { throw NativeSignedOutputError.unsupportedClaims }
        guard Set(dictionary.keys) == Set(["application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups", "get-task-allow"]),
              dictionary["application-identifier"] as? String == applicationIdentifier,
              dictionary["com.apple.developer.team-identifier"] as? String == teamIdentifier,
              dictionary["keychain-access-groups"] as? [String] == [applicationIdentifier],
              let debug = dictionary["get-task-allow"] as? NSNumber,
              CFGetTypeID(debug) == CFBooleanGetTypeID(), debug.boolValue,
              try payload(xmlBlob, magic: 0xfade7171) == expectedXML,
              try payload(derBlob, magic: 0xfade7172) == expected else { throw NativeSignedOutputError.unsupportedClaims }
    }

    static func canonicalDER(applicationIdentifier: String, teamIdentifier: String) throws -> Data {
        guard teamIdentifier.utf8.count == 10,
              teamIdentifier.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              applicationIdentifier.hasPrefix(teamIdentifier + "."),
              NativeAccountProvisioningRequest.isBundleIdentifier(String(applicationIdentifier.dropFirst(11))) else {
            throw NativeSignedOutputError.unsupportedClaims
        }
        func text(_ string: String) -> Data { tlv(0x0c, Data(string.utf8)) }
        let claims: [(String, Data)] = [
            ("application-identifier", text(applicationIdentifier)),
            ("com.apple.developer.team-identifier", text(teamIdentifier)),
            ("keychain-access-groups", tlv(0x30, text(applicationIdentifier))),
            ("get-task-allow", tlv(0x01, Data([0xff])))
        ]
        let pairs = claims.map { tlv(0x30, text($0.0) + $0.1) }.sorted { $0.lexicographicallyPrecedes($1) }
        return tlv(0x31, pairs.reduce(Data(), +))
    }

    private static func tlv(_ tag: UInt8, _ data: Data) -> Data {
        var length = data.count; var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        let encodedLength = data.count < 128 ? Data([UInt8(data.count)]) : Data([0x80 | UInt8(bytes.count)] + bytes)
        return Data([tag]) + encodedLength + data
    }
    private static func payload(_ blob: Data, magic: UInt32) throws -> Data {
        guard (9...64 * 1024 + 8).contains(blob.count) else { throw NativeSignedOutputError.unsupportedClaims }
        let bytes = Array(blob.prefix(8))
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        guard word(0) == magic, Int(word(4)) == blob.count else { throw NativeSignedOutputError.unsupportedClaims }
        return Data(blob.dropFirst(8))
    }
}
