import Foundation

struct FixtureSlotRecord: Codable {
    enum Phase: String, Codable { case rehearsal, ready, removalPlanned, reinstallUncertain, awaitingFixture, restored }
    let copyID: String
    var backup: FixtureSlotPacket
    var phase: Phase
    var challenge: UUID

    // Optional for journals saved before recovery rebinding was supported.
    var signingTeam: String? = nil
    var activeCopyID: String? = nil
    var anchorUUID: String? = nil
    var activeUUID: String? = nil

    var recoveryEntry: FixtureRecoveryEntry? {
        guard let anchorUUID, !anchorUUID.isEmpty, activeCopyID == nil || activeUUID?.isEmpty == false else { return nil }
        return .init(id: copyID, uuid: anchorUUID, activeUUID: activeUUID, bundle: backup.bundle)
    }

    mutating func rebind(to replacement: FixtureSlotBinding, previousTeam: String, now: Date = Date()) throws {
        guard signingTeam.map({ $0 == previousTeam }) ?? true,
              replacement.team == previousTeam, replacement.bundle == backup.bundle,
              replacement.expiry > now, replacement.profile != backup.profile else {
            throw PlanBlocked(reason: "Select a valid re-signed fixture from the original bundle and signing team.")
        }
        activeCopyID = replacement.copy
        signingTeam = previousTeam
        backup = .init(kind: .backup, bundle: backup.bundle, profile: replacement.profile, marker: backup.marker, challenge: nil)
        challenge = UUID()
        // Do not replay any pending install. A user must confirm the queue is clear before retry.
        switch phase {
        case .reinstallUncertain, .awaitingFixture: phase = .reinstallUncertain
        case .removalPlanned: break
        default: phase = .rehearsal
        }
    }

    mutating func accept(_ reply: FixtureSlotPacket) throws {
        guard phase == .rehearsal || phase == .removalPlanned || phase == .reinstallUncertain || phase == .awaitingFixture,
              reply == backup.with(phase == .rehearsal ? .rehearsed : .restored, challenge: challenge) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        phase = phase == .rehearsal ? .ready : .restored
    }

    /// A slot is a standalone app, not a guest import, exported IPA or external handoff.
    /// Check the current pipeline before journaling an attempted submission.
    static func reinstallBlocker(_ report: InstallMethodReport) -> String? {
        switch report.method {
        case .server, .idevice: break
        case .liveContainer, .export, .trollstore:
            return String(localized: "Select a standalone OTA or paired-device install method for this fixture.")
        }
        switch report.readiness {
        case .ready: return nil
        case .unknown(let reason), .missing(let reason), .unavailable(let reason): return reason
        }
    }

    /// The user kept the original fixture. Invalidate the abandoned restore packet
    /// and require a fresh rehearsal; never discard the only captured marker.
    mutating func cancelUnsubmittedPlan() throws {
        guard phase == .removalPlanned else { throw CocoaError(.fileReadCorruptFile) }
        challenge = UUID()
        phase = .rehearsal
    }

    mutating func beginReinstall() throws {
        guard phase == .removalPlanned else { throw CocoaError(.fileReadCorruptFile) }
        phase = .reinstallUncertain
    }

    mutating func acknowledgeSubmission() throws {
        guard phase == .reinstallUncertain else { throw CocoaError(.fileReadCorruptFile) }
        phase = .awaitingFixture
    }

    mutating func allowManualRetry() throws {
        guard phase == .awaitingFixture || phase == .reinstallUncertain else { throw CocoaError(.fileReadCorruptFile) }
        challenge = UUID() // invalidate a late reply from the previous attempt
        phase = .removalPlanned
    }

    struct PlanBlocked: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    mutating func planRemoval(route: InstallMethodReport, verification: DirectInstallVerification) throws {
        guard phase == .ready else { throw CocoaError(.fileReadCorruptFile) }
        if let reason = Self.reinstallBlocker(route) { throw PlanBlocked(reason: reason) }
        guard verification.isSigned, !verification.hasBlockingIssues else {
            throw PlanBlocked(reason: ([String(localized: "Keep the fixture installed: the retained copy failed signature checks.")] + verification.issues).joined(separator: "\n"))
        }
        challenge = UUID(); phase = .removalPlanned
    }
}

/// A protected local rehearsal journal. Exclude it from migration/backups: the rehearsal
/// and the library copy belong to this installation, not another device with the same ID.
struct FixtureSlotBinding {
    let copy: String
    let bundle: String
    let profile: String
    let team: String
    let expiry: Date
}

struct FixtureRecoveryEntry: Identifiable {
    let id: String
    let uuid: String
    let activeUUID: String?
    let bundle: String
}

enum FixtureSlotStorage {
    static func binding(_ app: AppInfoPresentable, forHistoricalReview: Bool = false) throws -> FixtureSlotBinding {
        guard app.isSigned, let copy = app.workspaceIdentity, let url = app.bundleURL,
              let info = Bundle(url: url)?.infoDictionary, info["VexSignMarkerFixture"] as? Bool == true,
              let bundle = app.identifier, info["CFBundleIdentifier"] as? String == bundle,
              DeviceAppRemoval.refusal(for: bundle, ownBundleIdentifier: Bundle.main.bundleIdentifier) == nil else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let data = try CertificateInputReader.read(url.appendingPathComponent("embedded.mobileprovision"))
        let parsed = try ProvisioningProfileParser.parse(data, allowingExpiredForDisplay: forHistoricalReview)
        guard let team = parsed.TeamIdentifier.first, parsed.CreationDate <= Date() else { throw CocoaError(.fileReadCorruptFile) }
        return .init(copy: copy, bundle: bundle, profile: FixtureSlotPacket.digest(data), team: team, expiry: parsed.ExpirationDate)
    }

    private static func directory() throws -> URL {
        let fm = FileManager.default
        var dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FixtureSlotRecords", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        return dir
    }
    private static func location(_ copy: String) throws -> URL {
        try directory().appendingPathComponent(FixtureSlotPacket.digest(Data(copy.utf8)) + ".json")
    }
    static func load(_ copy: String) throws -> FixtureSlotRecord? {
        let url = try location(copy)
        do {
            let record = try JSONDecoder().decode(FixtureSlotRecord.self, from: Data(contentsOf: url))
            guard record.copyID == copy else { throw CocoaError(.fileReadCorruptFile) }
            return record
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    static func recoveryEntries() throws -> [FixtureRecoveryEntry] {
        let files = try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.compactMap { url in
            let bytes = try CertificateInputReader.read(url, maximumBytes: 16384)
            let row = try JSONDecoder().decode(FixtureSlotRecord.self, from: bytes)
            guard url.deletingPathExtension().lastPathComponent == FixtureSlotPacket.digest(Data(row.copyID.utf8)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return row.recoveryEntry
        }.sorted { ($0.bundle, $0.id) < ($1.bundle, $1.id) }
    }
    static func save(_ record: FixtureSlotRecord) throws {
        try JSONEncoder().encode(record).write(to: location(record.copyID), options: [.atomic, .completeFileProtection])
    }
}
