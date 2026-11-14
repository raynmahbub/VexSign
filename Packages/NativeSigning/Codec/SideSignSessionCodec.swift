import Foundation
import SideSign

public enum SideSignSessionCodecError: Error, Equatable {
    case invalidSize
    case malformedRecord
    case unsupportedVersion
    case invalidFields
    case unsupportedMachinePassword
    case unknownExpiry
    case expired
}

/// Explicit session-token allowlist, NOT AuthSession's synthesized Codable form.
/// Output is secret plaintext bytes for the device-only Keychain adapter ONLY.
/// No files/preferences/logging. No Apple password, 2FA response, machine password,
/// anisette headers/OTP or account display names are persisted.
public enum SideSignSessionCodec {
    public static let maximumBytes = 1024 * 1024
    public static let sdkRevision = "2664dadedf9aca36fda0925a8aada92e2c79323f"

    private struct Record: Codable {
        let schema: Int
        let sdkRevision: String
        let accountIdentifier: String
        let appleID: String
        let dsid: String
        let authToken: String
        let xcodeVersion: String
        let createdAt: Date?
        let expiresAt: Date

        enum CodingKeys: String, CodingKey, CaseIterable {
            case schema, sdkRevision, accountIdentifier, appleID, dsid, authToken
            case xcodeVersion, createdAt, expiresAt
        }
    }

    public static func encode(_ value: AuthSession, now: Date) throws -> Data {
        let session = value.session
        // Do not silently drop a credential whose necessity has not been audited.
        guard session.machinePassword == nil else {
            throw SideSignSessionCodecError.unsupportedMachinePassword
        }
        guard now.timeIntervalSince1970.isFinite else { throw SideSignSessionCodecError.invalidFields }
        var deadlines: [Date] = []
        if let expiry = session.expirationDate { deadlines.append(expiry) }
        if let ttl = session.timeToLive {
            guard ttl.isFinite, ttl > 0 else { throw SideSignSessionCodecError.invalidFields }
            if let created = session.creationDate { deadlines.append(created.addingTimeInterval(ttl)) }
        }
        guard deadlines.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
            throw SideSignSessionCodecError.invalidFields
        }
        guard let expiry = deadlines.min() else { throw SideSignSessionCodecError.unknownExpiry }
        let record = Record(
            schema: 1, sdkRevision: sdkRevision,
            accountIdentifier: value.account.identifier, appleID: value.account.appleID,
            dsid: session.dsid, authToken: session.authToken, xcodeVersion: session.xcodeVersion,
            createdAt: session.creationDate, expiresAt: expiry
        )
        try validate(record, now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        // Normalize encoder errors; never expose arbitrary payloads through errors.
        guard let data = try? encoder.encode(record) else { throw SideSignSessionCodecError.malformedRecord }
        guard data.count <= maximumBytes else { throw SideSignSessionCodecError.invalidSize }
        return data
    }

    /// Restores a candidate for server revalidation, NOT an authenticated signing
    /// context. The caller must obtain fresh anisette headers from its consented
    /// provider and revalidate the account/token/teams with Apple before publishing
    /// signed-in state. Local expiry cannot detect server invalidation/revocation.
    public static func decodeForRevalidation(
        _ data: Data, freshAnisetteData: AnisetteData, now: Date
    ) throws -> AuthSession {
        let record = try readRecord(data, now: now)
        try validateFreshHeaders(freshAnisetteData)
        return AuthSession(
            account: Account(appleID: record.appleID, identifier: record.accountIdentifier),
            session: Session(
                dsid: record.dsid, authToken: record.authToken, anisetteData: freshAnisetteData,
                xcodeVersion: record.xcodeVersion, machinePassword: nil,
                creationDate: record.createdAt, expirationDate: record.expiresAt,
                timeToLive: record.createdAt.map { record.expiresAt.timeIntervalSince($0) }
            )
        )
    }

    /// Internal stable owner binding only, after the coordinator has authorized
    /// the selected context. Does not restore a session or fabricate anisette.
    static func identityOwner(_ data: Data, teamIdentifier: String, now: Date) throws -> NativeSigningIdentityOwner {
        let record = try readRecord(data, now: now)
        return try NativeSigningIdentityOwner(accountIdentifier: record.accountIdentifier,
                                              dsid: record.dsid, teamIdentifier: teamIdentifier)
    }

    private static func readRecord(_ data: Data, now: Date) throws -> Record {
        guard !data.isEmpty, data.count <= maximumBytes else { throw SideSignSessionCodecError.invalidSize }
        // Reject unexpected fields instead of silently accepting a future schema
        // carrying material outside this persistence allowlist.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: Set(Record.CodingKeys.allCases.map(\.rawValue))) else {
            throw SideSignSessionCodecError.malformedRecord
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let record = try? decoder.decode(Record.self, from: data) else {
            throw SideSignSessionCodecError.malformedRecord
        }
        guard record.schema == 1, record.sdkRevision == sdkRevision else {
            throw SideSignSessionCodecError.unsupportedVersion
        }
        try validate(record, now: now)
        return record
    }

    private static func validate(_ record: Record, now: Date) throws {
        let fields = [record.accountIdentifier, record.appleID, record.dsid, record.authToken, record.xcodeVersion]
        guard fields.allSatisfy(validField), now.timeIntervalSince1970.isFinite,
              record.expiresAt.timeIntervalSince1970.isFinite else {
            throw SideSignSessionCodecError.invalidFields
        }
        if let created = record.createdAt {
            guard created.timeIntervalSince1970.isFinite, created <= now, created < record.expiresAt else {
                throw SideSignSessionCodecError.invalidFields
            }
        }
        guard record.expiresAt > now else { throw SideSignSessionCodecError.expired }
    }

    private static func validField(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 65_536
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func validateFreshHeaders(_ value: AnisetteData) throws {
        let fields = [value.machineID, value.oneTimePassword, value.localUserID, value.routingInfo,
                      value.deviceID, value.serialNumber, value.clientInfo, value.userAgent,
                      value.clientTime, value.locale, value.timeZone]
        guard fields.allSatisfy(validField) else { throw SideSignSessionCodecError.invalidFields }
    }
}
