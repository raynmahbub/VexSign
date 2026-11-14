import Foundation
import Security
import LocalAuthentication
import os
import SideSign

public enum NativeV3AnisetteError: Error, Equatable, Sendable {
    case busy, invalidState, storageUnavailable, invalidResponse
}

struct NativeV3AnisetteState: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "NativeV3AnisetteState(redacted)" }
    var debugDescription: String { description }
    let identifier: UUID
    var adiBlob: Data?
    func validate() throws {
        if let adiBlob, adiBlob.isEmpty || adiBlob.count > 64 * 1024 {
            throw NativeV3AnisetteError.invalidState
        }
    }
}

protocol NativeV3AnisetteStateStorage: Sendable {
    func load() throws -> NativeV3AnisetteState?
    func save(_ state: NativeV3AnisetteState) throws
}

/// Separate from Apple credentials and from the hash-only mutation journals.
/// No preference fallback, shared access group, sync, guest access or reset API.
struct NativeV3AnisetteKeychainStore: NativeV3AnisetteStateStorage {
    let scope: String
    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.vexsign.native-anisette.v3.v1",
         kSecAttrAccount as String: scope, kSecAttrSynchronizable as String: false]
    }
    func load() throws -> NativeV3AnisetteState? {
        try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime()
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let result = SystemAppleAccountKeychainClient().copy(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else { throw NativeV3AnisetteError.storageUnavailable }
        guard let data = result.data, !data.isEmpty, data.count <= 96 * 1024 else {
            throw NativeV3AnisetteError.invalidState
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["identifier", "adiBlob"]) else { throw NativeV3AnisetteError.invalidState }
            let state = try JSONDecoder().decode(NativeV3AnisetteState.self, from: data)
            try state.validate()
            return state
        } catch { throw NativeV3AnisetteError.invalidState }
    }
    func save(_ state: NativeV3AnisetteState) throws {
        try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime()
        try state.validate()
        let data = try JSONEncoder().encode(state)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let client = SystemAppleAccountKeychainClient()
        var attributes = base
        attributes.merge(values) { _, value in value }
        let status = client.add(attributes)
        if status == errSecDuplicateItem {
            guard client.update(base, attributes: values) == errSecSuccess else { throw NativeV3AnisetteError.storageUnavailable }
        } else if status != errSecSuccess { throw NativeV3AnisetteError.storageUnavailable }
    }
}

protocol NativeV3AnisetteTransport: Sendable {
    func headers(identifier: UUID, blob: Data?) async throws -> (data: AnisetteData, blob: Data?)
}

/// The existing SDK performs the Apple ADI start/end exchange. It receives no
/// Apple ID, password, portal session or 2FA code from this provider.
actor SystemNativeV3AnisetteTransport: NativeV3AnisetteTransport {
    private let manager: AnisetteDataManager
    init(endpoint: URL, directory: URL) {
        manager = AnisetteDataManager(mode: .remote(server: endpoint), baseDirectory: directory,
                                      allowsLegacyFallback: false)
    }
    func headers(identifier: UUID, blob: Data?) async throws -> (data: AnisetteData, blob: Data?) {
        manager.clearCache()
        let result = try await manager.fetchAnisetteData(identifier: identifier, existingAdiBlob: blob)
        return (result.data, result.newAdiBlob)
    }
}

/// Invoked only behind the bridge's provider-bound consent gate. Persisted ADI
/// material is not consent: every account operation still needs a fresh grant.
public actor NativeV3AnisetteProvider: ConsentedAnisetteProvider {
    public nonisolated let descriptor: AnisetteProviderDescriptor
    private let transport: any NativeV3AnisetteTransport
    private let storage: any NativeV3AnisetteStateStorage
    private var busy = false
    private let scope: String?
    private static let activeScopes = OSAllocatedUnfairLock(initialState: Set<String>())

    init(descriptor: AnisetteProviderDescriptor, transport: any NativeV3AnisetteTransport,
         storage: any NativeV3AnisetteStateStorage) throws {
        guard descriptor.protocolKind == .v3, descriptor.endpoint != nil else { throw AnisetteConsentError.invalidProvider }
        self.scope = nil
        self.descriptor = descriptor; self.transport = transport; self.storage = storage
    }

    public init(descriptor: AnisetteProviderDescriptor) throws {
        guard descriptor.protocolKind == .v3, let endpoint = descriptor.endpoint else { throw AnisetteConsentError.invalidProvider }
        try AppleAccountStorageRuntimePolicy.requirePrimaryRuntime()
        // Length-delimited identity/policy/endpoint binding. Changing operator or
        // policy never sends another provider's ADI blob to the new endpoint.
        let fields = [descriptor.identifier, descriptor.policyRevision, endpoint.absoluteString]
        let scope = NativeSigningIdentityOwner.hash(try JSONEncoder().encode(fields))
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NativeV3AnisetteError.storageUnavailable
        }
        self.descriptor = descriptor
        self.scope = scope
        storage = NativeV3AnisetteKeychainStore(scope: scope)
        transport = SystemNativeV3AnisetteTransport(endpoint: endpoint,
            directory: support.appendingPathComponent("NativeAnisetteV3").appendingPathComponent(scope))
    }

    public func freshHeaders() async throws -> AnisetteData {
        guard !busy else { throw NativeV3AnisetteError.busy }
        if let scope, !Self.activeScopes.withLock({ $0.insert(scope).inserted }) {
            throw NativeV3AnisetteError.busy
        }
        busy = true
        defer {
            busy = false
            if let scope { Self.activeScopes.withLock { _ = $0.remove(scope) } }
        }
        try Task.checkCancellation()
        var state = try storage.load() ?? NativeV3AnisetteState(identifier: UUID(), adiBlob: nil)
        try state.validate()
        // Make the pseudonymous identifier durable before provisioning starts.
        try storage.save(state)
        let result = try await transport.headers(identifier: state.identifier, blob: state.adiBlob)
        try Task.checkCancellation()
        try Self.validate(result.data, identifier: state.identifier, now: Date())
        guard result.blob != nil || state.adiBlob != nil else { throw NativeV3AnisetteError.invalidResponse }
        if let blob = result.blob {
            state.adiBlob = blob
            try state.validate()
            try storage.save(state)
        }
        return result.data
    }

    static func validate(_ data: AnisetteData, identifier: UUID, now: Date) throws {
        let values = [data.machineID, data.oneTimePassword, data.localUserID, data.routingInfo,
                      data.deviceID, data.serialNumber, data.clientInfo, data.userAgent,
                      data.clientTime, data.locale, data.timeZone]
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.utf8.count <= 4096
            && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              let machine = Data(base64Encoded: data.machineID), !machine.isEmpty,
              let otp = Data(base64Encoded: data.oneTimePassword), !otp.isEmpty,
              UUID(uuidString: data.deviceID) == identifier,
              data.routingInfo.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw NativeV3AnisetteError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var issued = formatter.date(from: data.clientTime)
        if issued == nil {
            formatter.formatOptions = [.withInternetDateTime]
            issued = formatter.date(from: data.clientTime)
        }
        guard let issued, now.timeIntervalSince1970.isFinite,
              abs(now.timeIntervalSince(issued)) <= 300 else { throw NativeV3AnisetteError.invalidResponse }
    }

}

/// One bridge type preserves the same account/consent state machine for both protocols.
enum NativeConfiguredAnisetteProvider: ConsentedAnisetteProvider {
    case headers(HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>)
    case v3(NativeV3AnisetteProvider)
    init(descriptor: AnisetteProviderDescriptor) throws {
        switch descriptor.protocolKind {
        case .headers: self = .headers(try .init(descriptor: descriptor))
        case .v3: self = .v3(try .init(descriptor: descriptor))
        }
    }
    var descriptor: AnisetteProviderDescriptor {
        switch self { case .headers(let value): value.descriptor; case .v3(let value): value.descriptor }
    }
    func freshHeaders() async throws -> AnisetteData {
        switch self { case .headers(let value): try await value.freshHeaders(); case .v3(let value): try await value.freshHeaders() }
    }
}
