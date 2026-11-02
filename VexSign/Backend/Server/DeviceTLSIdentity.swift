import Foundation
import Security

/// A device-local CA and loopback server identity, never shipped in an IPA or downloaded.
/// Keychain is the source of truth; files are only a protected cache for NIOSSL.
/// Renewal keeps the CA. Corrupt storage/expired CA fail closed, never silently rotate trust.
enum DeviceTLSIdentity {
    private static let lock = NSLock()
    private static let service = "VexSign.LocalInstallTLS.v1"
    private static let account = "identity"
    private static let host = "127.0.0.1"

    struct Identity: Codable {
        var rootKey: Data
        var rootCertificate: Data
        var rootExpiry: Date
        var leafKey: Data
        var leafCertificate: Data
        var leafExpiry: Date
    }

    enum Failure: LocalizedError {
        case storage(OSStatus)
        case invalidIdentity
        case expiredCA
        var errorDescription: String? {
            switch self {
            case .storage(let status): return "Local TLS Keychain access failed (\(status)). Unlock the device and try again."
            case .invalidIdentity: return "The saved local TLS identity is invalid. It was not replaced."
            case .expiredCA: return "The local CA has expired. A new CA and trust profile must be explicitly configured; trust was not silently changed."
            }
        }
    }

    static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("LocalInstallTLS", isDirectory: true)
    }

    /// Called before serving TLS or exporting the trust profile. Never falls back to bundle keys.
    static func ensure() throws {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let saved = try load()
        var identity: Identity
        if let saved {
            guard saved.rootExpiry > now.addingTimeInterval(86400) else { throw Failure.expiredCA }
            identity = saved
            if saved.leafExpiry < now.addingTimeInterval(7 * 86400) {
                identity = try renew(saved)
                try save(identity, updating: true)
            }
        } else {
            identity = try generate()
            // Persist before exporting anything; a write failure cannot create an ephemeral trusted CA.
            try save(identity, updating: false)
        }
        try cache(identity)
    }

    /// Only after the user explicitly accepts installing/trusting a different CA.
    static func rotate() throws {
        lock.lock()
        defer { lock.unlock() }
        let identity = try generate()
        // Construct everything first, so a generation error preserves the old identity.
        do { try save(identity, updating: true) }
        catch Failure.storage(let status) where status == errSecItemNotFound { try save(identity, updating: false) }
        try cache(identity)
    }

    /// Pure generation seam for native certificate/signature tests (no Keychain writes).
    static func generate() throws -> Identity {
        let root = try newKey()
        let leaf = try newKey()
        let now = Date()
        let rootExpiry = now.addingTimeInterval(3650 * 86400)
        let leafExpiry = now.addingTimeInterval(397 * 86400)
        return Identity(rootKey: try external(root),
            rootCertificate: try certificate(subject: "VexSign Device Local CA", issuer: "VexSign Device Local CA",
                publicKey: root, signer: root, ca: true, until: rootExpiry),
            rootExpiry: rootExpiry, leafKey: try external(leaf),
            leafCertificate: try certificate(subject: "VexSign Local Server", issuer: "VexSign Device Local CA",
                publicKey: leaf, signer: root, ca: false, until: leafExpiry), leafExpiry: leafExpiry)
    }

    static func renew(_ saved: Identity, now: Date = Date()) throws -> Identity {
        guard saved.rootExpiry > now.addingTimeInterval(86400) else { throw Failure.expiredCA }
        var identity = saved
        let leaf = try newKey()
        identity.leafKey = try external(leaf)
        identity.leafExpiry = min(now.addingTimeInterval(397 * 86400), saved.rootExpiry)
        identity.leafCertificate = try certificate(subject: "VexSign Local Server", issuer: "VexSign Device Local CA",
            publicKey: leaf, signer: try key(from: saved.rootKey), ca: false, until: identity.leafExpiry)
        return identity
    }

    private static func cache(_ identity: Identity) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                               .posixPermissions: 0o700])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let chain = pem("CERTIFICATE", identity.leafCertificate) + pem("CERTIFICATE", identity.rootCertificate)
        try write(Data(chain.utf8), name: "server.crt")
        try write(Data(pem("RSA PRIVATE KEY", identity.leafKey).utf8), name: "server.pem")
        try write(Data(host.utf8), name: "commonName.txt")
    }

    private static func write(_ data: Data, name: String) throws {
        let url = directory.appendingPathComponent(name)
        var needsWrite = true
        if FileManager.default.fileExists(atPath: url.path) {
            needsWrite = try Data(contentsOf: url) != data
        }
        if needsWrite {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    private static func load() throws -> Identity? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.storage(status) }
        guard let data = value as? Data else { throw Failure.invalidIdentity }
        let identity = try JSONDecoder().decode(Identity.self, from: data)
        guard let root = SecCertificateCreateWithData(nil, identity.rootCertificate as CFData),
              let leaf = SecCertificateCreateWithData(nil, identity.leafCertificate as CFData),
              let rootPublic = SecCertificateCopyKey(root),
              let leafPublic = SecCertificateCopyKey(leaf),
              let rootKeyPublic = SecKeyCopyPublicKey(try key(from: identity.rootKey)),
              let leafKeyPublic = SecKeyCopyPublicKey(try key(from: identity.leafKey)),
              try external(rootPublic) == external(rootKeyPublic),
              try external(leafPublic) == external(leafKeyPublic) else { throw Failure.invalidIdentity }
        return identity
    }

    private static func save(_ identity: Identity, updating: Bool) throws {
        let data = try JSONEncoder().encode(identity)
        let status: OSStatus
        if updating {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.storage(status) }
    }

    private static func newKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048] as CFDictionary, &error) else {
            throw Failure.invalidIdentity
        }
        return key
    }

    private static func key(from data: Data) throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate] as CFDictionary, &error) else {
            throw Failure.invalidIdentity
        }
        return key
    }

    private static func external(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw Failure.invalidIdentity }
        return data
    }

    // Small, fixed-schema DER encoder: no remote ASN.1, parameters or algorithm selection.
    static func der(_ tag: UInt8, _ body: Data) -> Data {
        var length = body.count
        var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        let header = body.count < 128 ? [UInt8(body.count)] : [0x80 | UInt8(bytes.count)] + bytes
        return Data([tag] + header) + body
    }
    private static func seq(_ parts: Data...) -> Data { der(0x30, parts.reduce(Data(), +)) }
    private static func oid(_ bytes: [UInt8]) -> Data { der(0x06, Data(bytes)) }
    private static let algorithm = seq(oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,11]), der(0x05, Data()))
    private static func name(_ value: String) -> Data {
        seq(der(0x31, seq(oid([0x55,4,3]), der(0x0c, Data(value.utf8)))))
    }
    private static func time(_ value: Date) -> Data {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyMMddHHmmss'Z'"
        return der(0x17, Data(format.string(from: value).utf8))
    }
    private static func ext(_ number: UInt8, _ content: Data, critical: Bool = false) -> Data {
        seq(oid([0x55,0x1d,number]), critical ? der(1, Data([0xff])) : Data(), der(4, content))
    }
    private static func certificate(subject: String, issuer: String, publicKey: SecKey,
                                    signer: SecKey, ca: Bool, until: Date) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(publicKey) else { throw Failure.invalidIdentity }
        let spki = seq(seq(oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,1]), der(5, Data())),
                       der(3, Data([0]) + (try external(publicKey))))
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else { throw Failure.invalidIdentity }
        serial[0] = (serial[0] & 0x7f) | 1
        var extensions = ext(19, ca ? seq(der(1, Data([0xff])), der(2, Data([0]))) : seq(), critical: true)
        extensions += ext(15, der(3, ca ? Data([1,6]) : Data([5,0xa0])), critical: true)
        if !ca {
            extensions += ext(37, seq(oid([0x2b,6,1,5,5,7,3,1])))
            extensions += ext(17, seq(der(0x87, Data([127,0,0,1])), der(0x82, Data("localhost".utf8))))
        }
        let tbs = seq(der(0xa0, der(2, Data([2]))), der(2, Data(serial)), algorithm, name(issuer),
                      seq(time(Date().addingTimeInterval(-300)), time(until)), name(subject), spki, der(0xa3, seq(extensions)))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(signer, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            throw Failure.invalidIdentity
        }
        return seq(tbs, algorithm, der(3, Data([0]) + signature))
    }
    private static func pem(_ kind: String, _ data: Data) -> String {
        let base64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(kind)-----\n\(base64)\n-----END \(kind)-----\n"
    }
}
