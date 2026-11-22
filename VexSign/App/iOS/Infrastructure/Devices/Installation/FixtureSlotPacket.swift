import Foundation
import CryptoKit

/// Interop for the disposable marker fixture only. Not an attestation protocol for arbitrary apps.
struct FixtureSlotPacket: Codable, Equatable {
    enum Kind: String, Codable { case backup, rehearse, restore, rehearsed, restored }
    let kind: Kind
    let bundle: String
    let profile: String
    let marker: UUID
    let challenge: UUID?

    func with(_ kind: Kind, challenge: UUID?) -> Self {
        Self(kind: kind, bundle: bundle, profile: profile, marker: marker, challenge: challenge)
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func text() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 2048 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }
}
