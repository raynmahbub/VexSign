//
//  Heartbeat.swift
//  Feather / IDeviceKit (MIT). See LICENSE and VexSign's vendor patch review.
//
// VexSign local maintenance: one serial native executor, operation-scoped sessions,
// format-aware routing and no global/borrowed native handles. No autonomous pairing.
import Foundation

public final class HeartbeatManager {
    public static let shared = HeartbeatManager()
    private let executor = DeviceOperationExecutor()
    private init() {}

    public static func pairingFile() -> String { PairingFileStorage.path() }
    public var isBusy: Bool { executor.isBusy }

    /// Source-compatible reset only. Sessions are fresh, explicit and scoped to
    /// one operation; launch/foreground never initiates an unsolicited handshake.
    public func start(_ forceRestart: Bool = false) {
        if forceRestart { cancelDeviceOperations() }
    }

    public func cancelDeviceOperations() { executor.cancel() }

    /// Local credential recovery only; never opens a socket or native session.
    public func recoverPairingStorage() async throws {
        try await serialized { _ -> Void in }
    }

    func serialized<Value>(_ work: @escaping (Progress) throws -> Value) async throws -> Value {
        try await executor.run { cancellation in
            try PairingFileStorage.prepare()
            try DeviceServiceSession.check(cancellation)
            return try work(cancellation)
        }
    }

    func nativeOperation<Value>(waiterTimeout: TimeInterval = 30, _ work: @escaping (Progress) throws -> Value) async throws -> Value {
        // The executor clamps all native deadlines to 0.01...300 seconds. An
        // install may need the longer bound; a verification poll uses its budget.
        try await executor.run(waiterTimeout: waiterTimeout) { cancellation in
            try PairingFileStorage.prepare()
            try DeviceServiceSession.check(cancellation)
            return try work(cancellation)
        }
    }

    public func currentPairingReview() async throws -> PairingRecordReview {
        try await serialized { _ in
            do {
                let data = try PairingFileStorage.read(from: URL(fileURLWithPath: Self.pairingFile()))
                let fingerprint = PairingRecordDocument.fingerprint(data)
                do {
                    return PairingRecordReview(metadata: try PairingRecordDocument.inspect(data), fingerprint: fingerprint, issue: nil)
                } catch {
                    return PairingRecordReview(metadata: nil, fingerprint: fingerprint,
                        issue: (error as? PairingRecordError) ?? .malformed)
                }
            } catch {
                return PairingRecordReview(metadata: nil, fingerprint: nil,
                    issue: (error as? PairingRecordError) ?? .unreadable)
            }
        }
    }

    public func currentPairingRecord() async throws -> PairingRecordMetadata {
        try await inspectPairingRecord(from: URL(fileURLWithPath: Self.pairingFile()))
    }

    /// Inspection shares recovery/admission with connection and never performs
    /// an unbounded synchronous read on an app actor or presentation callback.
    public func inspectPairingRecord(from url: URL) async throws -> PairingRecordMetadata {
        try await serialized { _ in
            try PairingRecordDocument.inspect(PairingFileStorage.read(from: url))
        }
    }

    /// A bounded fingerprint can also review a malformed (but regular, <=2MiB)
    /// legacy record for explicit replacement/deletion. It never validates it.
    public func currentPairingFingerprint() async throws -> String {
        try await serialized { _ in
            PairingRecordDocument.fingerprint(try PairingFileStorage.read(from: URL(fileURLWithPath: Self.pairingFile())))
        }
    }

    func configuredRequest() throws -> DeviceConnectionRequest {
        let url = URL(fileURLWithPath: Self.pairingFile())
        let metadata = try PairingRecordDocument.inspect(PairingFileStorage.read(from: url))
        return DeviceConnectionRequest(pairingFile: url, expectedDeviceIdentifier: metadata.deviceIdentifier ?? "",
            peerAddress: UserDefaults.standard.string(forKey: "VexSign.devicePeerAddress") ?? "10.7.0.1",
            protocolConsent: UserDefaults.standard.bool(forKey: "VexSign.deviceProtocolConsent"))
    }

    public func queryDevice(request: DeviceConnectionRequest? = nil,
                            reporting: @escaping (DeviceConnectionStage) -> Void = { _ in }) async throws -> AuthorizedDeviceSnapshot {
        try await withDeviceSession(request: request, reporting: reporting) { session, _ in
            guard let snapshot = session.snapshot else { throw DeviceTransportError.invalidDeviceResponse }
            return snapshot
        }
    }

    @discardableResult
    public func importPairingRecord(from url: URL, replacing expectedSHA256: String? = nil) async throws -> PairingRecordMetadata {
        try await serialized { cancellation in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try PairingFileStorage.read(from: url)
            try DeviceServiceSession.check(cancellation)
            return try PairingFileStorage.install(data, at: URL(fileURLWithPath: Self.pairingFile()), replacing: expectedSHA256)
        }
    }

    public func deletePairingRecord(expectedSHA256: String) async throws {
        try await serialized { _ in
            try PairingFileStorage.remove(at: URL(fileURLWithPath: Self.pairingFile()), expectedSHA256: expectedSHA256)
        }
    }

    public func exportPairingRecord(expectedSHA256: String) async throws -> URL {
        try await serialized { _ in
            try PairingFileStorage.export(from: URL(fileURLWithPath: Self.pairingFile()), expectedSHA256: expectedSHA256)
        }
    }
}
