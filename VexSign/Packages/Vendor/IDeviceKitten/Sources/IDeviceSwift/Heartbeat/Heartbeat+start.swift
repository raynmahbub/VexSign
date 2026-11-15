// Heartbeat+start.swift — VexSign local maintenance; MIT upstream notice retained.
import Foundation

extension HeartbeatManager {
    /// Reconnect for every native operation. Non-null cached pointers are not
    /// evidence that a VPN/session survived backgrounding or record replacement.
    func withDeviceSession<Value>(request: DeviceConnectionRequest? = nil,
                                  waiterTimeout: TimeInterval = 30,
                                  reporting: @escaping (DeviceConnectionStage) -> Void = { _ in },
                                  _ work: @escaping (DeviceServiceSession, Progress) throws -> Value) async throws -> Value {
        try await nativeOperation(waiterTimeout: waiterTimeout) { cancellation in
            reporting(.inspectingRecord)
            let selected = try request ?? self.configuredRequest()
            let data = try PairingFileStorage.read(from: selected.pairingFile)
            let metadata = try PairingRecordDocument.inspect(data)
            if let expected = selected.expectedPairingSHA256, expected != metadata.sha256 {
                throw PairingRecordError.changedRecord
            }
            let session = DeviceServiceSession()
            defer { reporting(.disconnecting); session.close() }
            try session.open(selected, recordBytes: data, metadata: metadata, cancellation: cancellation, reporting: reporting)
            // The parser used our bounded snapshot. Also refuse operations if the
            // selected record was replaced while the connection was opening.
            guard PairingRecordDocument.fingerprint(try PairingFileStorage.read(from: selected.pairingFile)) == metadata.sha256 else {
                throw PairingRecordError.changedRecord
            }
            return try work(session, cancellation)
        }
    }
}
