import Foundation

public enum NativeRegistrationError: Error, Equatable, Sendable {
    case invalidRequest, approvalRequired, busy, inventoryRejected
    case reconciliationRequired, storageUnavailable, invalidJournal, requestFailed
}

public struct NativeRegistrationSubject: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: String, Sendable { case device, appID }
    public let kind: Kind
    let value: String
    public init(kind: Kind, value: String) throws {
        switch kind {
        case .device:
            do { _ = try NativeAccountProvisioningRequest(deviceIdentifier: value, bundleIdentifiers: ["validation.placeholder"]) }
            catch { throw NativeRegistrationError.invalidRequest }
        case .appID:
            guard NativeAccountProvisioningRequest.isBundleIdentifier(value) else { throw NativeRegistrationError.invalidRequest }
        }
        self.kind = kind
        self.value = kind == .device ? value.uppercased() : value
    }
    var digest: String { NativeSigningIdentityOwner.hash(Data(("VexSign registration v1\0" + kind.rawValue + "\0" + value.lowercased()).utf8)) }
    var approvalDigest: String { NativeSigningIdentityOwner.hash(Data(("VexSign registration approval v1\0" + kind.rawValue + "\0" + value).utf8)) }
    public var description: String { "NativeRegistrationSubject(redacted)" }
    public var debugDescription: String { description }
}

struct NativeRegistrationObservation: Sendable {
    let subject: NativeRegistrationSubject
    let remoteIdentifier: String
    let enabled: Bool
    let expiresAt: Date?
}

struct NativeRegistrationRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case uncertain, recorded }
    let schema: Int
    let id: UUID
    let ownerDigest: String
    let subjectDigest: String
    let createdAt: Date
    var phase: Phase
    var remoteIdentifierDigest: String?
    func validate(owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws {
        guard schema == 1, ownerDigest == owner.digest, subjectDigest == subject.digest,
              createdAt.timeIntervalSince1970.isFinite,
              (phase == .uncertain && remoteIdentifierDigest == nil)
                || (phase == .recorded && remoteIdentifierDigest.map(Self.validDigest) == true) else {
            throw NativeRegistrationError.invalidJournal
        }
    }
    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }
}

/// Add-only intent and UUID/phase-conditional forward commit. No reset/delete API.
protocol NativeRegistrationStorage: Sendable {
    func read(owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws -> NativeRegistrationRecord?
    func insertIntent(_ record: NativeRegistrationRecord, owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws
    func recordObservation(_ record: NativeRegistrationRecord, owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws
}

/// No production adapter is supplied yet. It must bind fresh account/free-team
/// validation and every request to this exact owner/context; use hardened bounded
/// transport, no SDK mutation retry/cleanup, and retain the account namespace lease.
protocol NativeRegistrationPortal: Sendable {
    func revalidateFreeAccount(owner: NativeSigningIdentityOwner, contextID: UUID) async throws
    func inventory(subject: NativeRegistrationSubject) async throws -> [NativeRegistrationObservation]
    func registerOnce(subject: NativeRegistrationSubject, operationID: UUID) async throws
}

struct NativeRegistrationApproval: Equatable, Sendable {
    let id: UUID
    let contextID: UUID
    let ownerDigest: String
    let subjectDigest: String
    let epoch: UUID
    let expiresAt: Date
}

public struct NativeRegistrationResult: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let remoteIdentifier: String
    // nil denotes a pre-existing server registration, not a new mutation.
    public let operationID: UUID?
    public var description: String { "NativeRegistrationResult(redacted)" }
    public var debugDescription: String { description }
}

/// Internal single-subject executor. Not a quota bypass, profile creator or UI
/// availability signal. The future bridge MUST also share its account busy gate.
actor NativeRegistrationExecutor<Store: NativeRegistrationStorage, Portal: NativeRegistrationPortal> {
    private let store: Store
    private let portal: Portal
    private let clock: @Sendable () -> Date
    private var epoch = UUID()
    private var approval: NativeRegistrationApproval?
    private var busy = false
    private var work: Task<NativeRegistrationResult, Error>?
    init(store: Store, portal: Portal, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.portal = portal; self.clock = clock
    }

    /// Call only after informed user approval of this exact quota-affecting item.
    /// No persistence, automatic renewal or approval inferred from anisette consent.
    func approve(owner: NativeSigningIdentityOwner, contextID: UUID, subject: NativeRegistrationSubject,
                 lifetime: TimeInterval = 120) throws -> NativeRegistrationApproval {
        try Task.checkCancellation()
        guard !busy, work == nil else { throw NativeRegistrationError.busy }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, lifetime.isFinite, lifetime > 0, lifetime <= 120 else {
            throw NativeRegistrationError.approvalRequired
        }
        if let existing = try store.read(owner: owner, subject: subject) {
            try existing.validate(owner: owner, subject: subject)
            throw NativeRegistrationError.reconciliationRequired
        }
        let grant = NativeRegistrationApproval(id: UUID(), contextID: contextID, ownerDigest: owner.digest,
            subjectDigest: subject.approvalDigest, epoch: epoch, expiresAt: now.addingTimeInterval(lifetime))
        approval = grant
        return grant
    }

    func revoke() { epoch = UUID(); approval = nil; work?.cancel() }

    func execute(owner: NativeSigningIdentityOwner, contextID: UUID, subject: NativeRegistrationSubject,
                 approval grant: NativeRegistrationApproval, authorityExpiresAt: Date,
                 checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> NativeRegistrationResult {
        guard work == nil else { throw NativeRegistrationError.busy }
        guard approval == grant else { throw NativeRegistrationError.approvalRequired }
        approval = nil // consume even on pre-intent failure
        return try await perform(owner: owner, contextID: contextID, subject: subject, grant: grant, authorityExpiresAt: authorityExpiresAt, checkCurrent: checkCurrent)
    }

    /// Never calls registerOnce, even when inventory is empty or a row is absent.
    func reconcile(owner: NativeSigningIdentityOwner, contextID: UUID, subject: NativeRegistrationSubject, authorityExpiresAt: Date,
                   checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> NativeRegistrationResult {
        try await perform(owner: owner, contextID: contextID, subject: subject, grant: nil, authorityExpiresAt: authorityExpiresAt, checkCurrent: checkCurrent)
    }

    private func perform(owner: NativeSigningIdentityOwner, contextID: UUID, subject: NativeRegistrationSubject,
                         grant: NativeRegistrationApproval?, authorityExpiresAt: Date,
                         checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> NativeRegistrationResult {
        guard work == nil else { throw NativeRegistrationError.busy }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, authorityExpiresAt.timeIntervalSince1970.isFinite,
              authorityExpiresAt > now else { throw NativeRegistrationError.approvalRequired }
        let deadline = min(authorityExpiresAt, min(grant?.expiresAt ?? authorityExpiresAt, now.addingTimeInterval(900)))
        let flow = epoch
        let worker = Task {
            try await self.run(owner: owner, contextID: contextID, subject: subject, grant: grant,
                               flow: flow, deadline: deadline, checkCurrent: checkCurrent)
        }
        work = worker
        let seconds = max(0, min(900, deadline.timeIntervalSince(now)))
        let timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            worker.cancel()
        }
        defer { timer.cancel(); work = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func run(owner: NativeSigningIdentityOwner, contextID: UUID, subject: NativeRegistrationSubject,
                     grant: NativeRegistrationApproval?, flow: UUID, deadline: Date, checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> NativeRegistrationResult {
        guard !busy else { throw NativeRegistrationError.busy }
        busy = true
        defer { busy = false }
        let check: @Sendable () async throws -> Void = {
            try Task.checkCancellation()
            try await checkCurrent()
            try Task.checkCancellation()
            try await self.requireCurrent(flow: flow, owner: owner, contextID: contextID, subject: subject, grant: grant, deadline: deadline)
        }
        do {
            try await check()
            let previous = try store.read(owner: owner, subject: subject)
            if let previous {
                try previous.validate(owner: owner, subject: subject)
                guard previous.createdAt <= clock() else { throw NativeRegistrationError.invalidJournal }
            }
            try await portal.revalidateFreeAccount(owner: owner, contextID: contextID)
            try await check()
            if let observed = try await observation(subject: subject, check: check) {
                try requireCurrent(flow: flow, owner: owner, contextID: contextID, subject: subject, grant: grant, deadline: deadline)
                return try finish(previous, observed: observed, owner: owner, subject: subject)
            }
            // A recorded row disappearing is also not permission to recreate it.
            guard previous == nil, grant != nil else { throw NativeRegistrationError.reconciliationRequired }
            try await portal.revalidateFreeAccount(owner: owner, contextID: contextID)
            try await check()
            let intent = NativeRegistrationRecord(schema: 1, id: UUID(), ownerDigest: owner.digest,
                subjectDigest: subject.digest, createdAt: clock(), phase: .uncertain, remoteIdentifierDigest: nil)
            try intent.validate(owner: owner, subject: subject)
            try store.insertIntent(intent, owner: owner, subject: subject)
            try await check() // cancellation/expiry leaves durable uncertainty
            try requireCurrent(flow: flow, owner: owner, contextID: contextID, subject: subject, grant: grant, deadline: deadline)
            try await portal.registerOnce(subject: subject, operationID: intent.id) // ONE application send
            try await check()
            guard let observed = try await observation(subject: subject, check: check) else {
                throw NativeRegistrationError.reconciliationRequired
            }
            try requireCurrent(flow: flow, owner: owner, contextID: contextID, subject: subject, grant: grant, deadline: deadline)
            return try finish(intent, observed: observed, owner: owner, subject: subject)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeRegistrationError { throw safe }
            throw NativeRegistrationError.requestFailed
        }
    }

    private func requireCurrent(flow: UUID, owner: NativeSigningIdentityOwner, contextID: UUID,
                                subject: NativeRegistrationSubject, grant: NativeRegistrationApproval?, deadline: Date) throws {
        let now = clock()
        guard flow == epoch, now.timeIntervalSince1970.isFinite, deadline > now else { throw NativeRegistrationError.approvalRequired }
        if let grant {
            guard grant.epoch == epoch, grant.contextID == contextID, grant.ownerDigest == owner.digest,
                  grant.subjectDigest == subject.approvalDigest, grant.expiresAt > now else { throw NativeRegistrationError.approvalRequired }
        }
    }

    private func observation(subject: NativeRegistrationSubject, check: @Sendable () async throws -> Void) async throws -> NativeRegistrationObservation? {
        let rows = try await portal.inventory(subject: subject)
        try await check()
        guard rows.count <= 1000, Set(rows.map(\.remoteIdentifier)).count == rows.count,
              rows.allSatisfy({ NativeRegistrationRecord.validIdentifier($0.remoteIdentifier)
                  && $0.subject.kind == subject.kind }) else { throw NativeRegistrationError.inventoryRejected }
        let matches = rows.filter { $0.subject.value.caseInsensitiveCompare(subject.value) == .orderedSame }
        guard matches.count <= 1 else { throw NativeRegistrationError.inventoryRejected }
        guard let match = matches.first else { return nil }
        guard match.subject == subject, match.enabled,
              match.expiresAt.map({ $0.timeIntervalSince1970.isFinite && $0 > clock() }) ?? true else {
            throw NativeRegistrationError.inventoryRejected
        }
        return match
    }

    private func finish(_ record: NativeRegistrationRecord?, observed: NativeRegistrationObservation,
                        owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws -> NativeRegistrationResult {
        try Task.checkCancellation()
        guard var record else { return .init(remoteIdentifier: observed.remoteIdentifier, operationID: nil) }
        if record.phase == .recorded {
            guard record.remoteIdentifierDigest == NativeSigningIdentityOwner.hash(Data(observed.remoteIdentifier.utf8)) else { throw NativeRegistrationError.reconciliationRequired }
        } else {
            record.phase = .recorded; record.remoteIdentifierDigest = NativeSigningIdentityOwner.hash(Data(observed.remoteIdentifier.utf8))
            try store.recordObservation(record, owner: owner, subject: subject)
        }
        return .init(remoteIdentifier: observed.remoteIdentifier, operationID: record.id)
    }
}

/// Type erasure keeps injected test journals and the production device-only
/// journal behind the same concrete executor generic without opening existentials.
struct NativeRegistrationStorageAdapter: NativeRegistrationStorage {
    let base: any NativeRegistrationStorage
    func read(owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws -> NativeRegistrationRecord? {
        try base.read(owner: owner, subject: subject)
    }
    func insertIntent(_ record: NativeRegistrationRecord, owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws {
        try base.insertIntent(record, owner: owner, subject: subject)
    }
    func recordObservation(_ record: NativeRegistrationRecord, owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws {
        try base.recordObservation(record, owner: owner, subject: subject)
    }
}
