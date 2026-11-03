import Foundation

/// Internal profile creation/recovery only; no production portal or CMS verifier
/// is selected. The absent verifier blocks even preflight/approval before I/O.
actor NativeProfileCreationExecutor<Store: NativeProfileCreationStorage, Portal: NativeProfileCreationPortal> {
    private let store: Store
    private let portal: Portal
    private let validator: NativeProvisioningProfileValidator
    private let clock: @Sendable () -> Date
    private var epoch = UUID()
    private var approval: NativeProfileCreationApproval?
    private var busy = false
    private var work: Task<NativeProfileCreationResult, Error>?
    init(store: Store, portal: Portal, validator: NativeProvisioningProfileValidator = .init(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.portal = portal; self.validator = validator; self.clock = clock
    }

    /// Call only after informed user approval of this exact quota-affecting item.
    /// No persistence, automatic renewal or approval inferred from anisette consent.
    func approve(owner: NativeSigningIdentityOwner, contextID: UUID, request: NativeProfileCreationRequest,
                 lifetime: TimeInterval = 120) throws -> NativeProfileCreationApproval {
        try Task.checkCancellation()
        try validator.requireCMSVerification()
        guard owner.teamIdentifier == request.validation.teamIdentifier, request.validation.expectedUUID == nil else {
            throw NativeProfileCreationError.invalidRequest
        }
        guard !busy, work == nil else { throw NativeProfileCreationError.busy }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, lifetime.isFinite, lifetime > 0, lifetime <= 120 else {
            throw NativeProfileCreationError.approvalRequired
        }
        if let existing = try store.read(owner: owner, request: request) {
            try existing.validate(owner: owner, request: request)
            throw NativeProfileCreationError.reconciliationRequired
        }
        let grant = NativeProfileCreationApproval(id: UUID(), contextID: contextID, ownerDigest: owner.digest,
            targetDigest: request.approvalDigest, epoch: epoch, expiresAt: now.addingTimeInterval(lifetime))
        approval = grant
        return grant
    }

    func revoke() { epoch = UUID(); approval = nil; work?.cancel() }

    func execute(owner: NativeSigningIdentityOwner, contextID: UUID, request: NativeProfileCreationRequest,
                 approval grant: NativeProfileCreationApproval, authorityExpiresAt: Date,
                 checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> NativeProfileCreationResult {
        guard work == nil else { throw NativeProfileCreationError.busy }
        guard approval == grant else { throw NativeProfileCreationError.approvalRequired }
        approval = nil // consume even on pre-intent failure
        return try await perform(owner: owner, contextID: contextID, request: request, grant: grant, authorityExpiresAt: authorityExpiresAt, checkCurrent: checkCurrent)
    }

    /// Never calls createOnce, even when inventory is empty or a row is absent.
    func reconcile(owner: NativeSigningIdentityOwner, contextID: UUID, request: NativeProfileCreationRequest, authorityExpiresAt: Date,
                   checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> NativeProfileCreationResult {
        try await perform(owner: owner, contextID: contextID, request: request, grant: nil, authorityExpiresAt: authorityExpiresAt, checkCurrent: checkCurrent)
    }

    private func perform(owner: NativeSigningIdentityOwner, contextID: UUID, request: NativeProfileCreationRequest,
                         grant: NativeProfileCreationApproval?, authorityExpiresAt: Date,
                         checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> NativeProfileCreationResult {
        try validator.requireCMSVerification()
        guard owner.teamIdentifier == request.validation.teamIdentifier else { throw NativeProfileCreationError.invalidRequest }
        guard work == nil else { throw NativeProfileCreationError.busy }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, authorityExpiresAt.timeIntervalSince1970.isFinite,
              authorityExpiresAt > now else { throw NativeProfileCreationError.approvalRequired }
        let deadline = min(authorityExpiresAt, min(grant?.expiresAt ?? authorityExpiresAt, now.addingTimeInterval(900)))
        let flow = epoch
        let worker = Task {
            try await self.run(owner: owner, contextID: contextID, request: request, grant: grant,
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

    private func run(owner: NativeSigningIdentityOwner, contextID: UUID, request: NativeProfileCreationRequest,
                     grant: NativeProfileCreationApproval?, flow: UUID, deadline: Date, checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> NativeProfileCreationResult {
        guard !busy else { throw NativeProfileCreationError.busy }
        busy = true
        defer { busy = false }
        let check: @Sendable () async throws -> Void = {
            try Task.checkCancellation()
            try await checkCurrent()
            try Task.checkCancellation()
            try await self.requireCurrent(flow: flow, owner: owner, contextID: contextID, request: request, grant: grant, deadline: deadline)
        }
        do {
            try await check()
            let previous = try store.read(owner: owner, request: request)
            if let previous {
                try previous.validate(owner: owner, request: request)
                guard previous.createdAt <= clock() else { throw NativeProfileCreationError.invalidJournal }
            }
            try await portal.revalidate(owner: owner, contextID: contextID, request: request)
            try await check()
            if let observed = try await observation(request: request, check: check) {
                try requireCurrent(flow: flow, owner: owner, contextID: contextID, request: request, grant: grant, deadline: deadline)
                return try finish(previous, observed: observed, owner: owner, request: request)
            }
            // A recorded row disappearing is also not permission to recreate it.
            guard previous == nil, grant != nil, request.validation.expectedUUID == nil else { throw NativeProfileCreationError.reconciliationRequired }
            try await portal.revalidate(owner: owner, contextID: contextID, request: request)
            try await check()
            let intent = NativeProfileCreationRecord(schema: 1, id: UUID(), ownerDigest: owner.digest,
                targetDigest: request.digest, createdAt: clock(), phase: .uncertain, remoteIdentifierDigest: nil, profileUUID: nil, cmsSHA256: nil)
            try intent.validate(owner: owner, request: request)
            try store.insertIntent(intent, owner: owner, request: request)
            try await check() // cancellation/expiry leaves durable uncertainty
            try requireCurrent(flow: flow, owner: owner, contextID: contextID, request: request, grant: grant, deadline: deadline)
            try await portal.createOnce(request: request, operationID: intent.id) // ONE application send
            try await check()
            guard let observed = try await observation(request: request, check: check) else {
                throw NativeProfileCreationError.reconciliationRequired
            }
            try requireCurrent(flow: flow, owner: owner, contextID: contextID, request: request, grant: grant, deadline: deadline)
            return try finish(intent, observed: observed, owner: owner, request: request)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeProfileCreationError { throw safe }
            if let safe = error as? NativeProfileValidationError { throw safe }
            throw NativeProfileCreationError.requestFailed
        }
    }

    private func requireCurrent(flow: UUID, owner: NativeSigningIdentityOwner, contextID: UUID,
                                request: NativeProfileCreationRequest, grant: NativeProfileCreationApproval?, deadline: Date) throws {
        let now = clock()
        guard flow == epoch, now.timeIntervalSince1970.isFinite, deadline > now else { throw NativeProfileCreationError.approvalRequired }
        if let grant {
            guard grant.epoch == epoch, grant.contextID == contextID, grant.ownerDigest == owner.digest,
                  grant.targetDigest == request.approvalDigest, grant.expiresAt > now else { throw NativeProfileCreationError.approvalRequired }
        }
    }

    private struct VerifiedObservation: Sendable {
        let remoteIdentifier: String
        let profile: NativeAuthenticatedProvisioningProfile
    }

    private func observation(request: NativeProfileCreationRequest, check: @Sendable () async throws -> Void) async throws -> VerifiedObservation? {
        let rows = try await portal.inventory(request: request)
        try await check()
        guard rows.count <= 50,
              rows.allSatisfy({ NativeRegistrationRecord.validIdentifier($0.remoteIdentifier) && !$0.cms.isEmpty && $0.cms.count <= 1024 * 1024 }),
              rows.reduce(0, { $0 + $1.cms.count }) <= 4 * 1024 * 1024,
              Set(rows.map(\.remoteIdentifier)).count == rows.count,
              Set(rows.map { NativeSigningIdentityOwner.hash($0.cms) }).count == rows.count else {
            throw NativeProfileCreationError.inventoryRejected
        }
        var verified: [VerifiedObservation] = []
        for row in rows {
            // No extracting a plist and guessing validity. Any bad CMS or target
            // mismatch in targeted inventory blocks adoption AND new creation.
            let profile = try await validator.validate(cms: row.cms, request: request.validation, now: clock())
            try await check()
            guard row.listedUUID.map({ $0 == profile.constraints.uuid }) ?? true else { throw NativeProfileCreationError.inventoryRejected }
            verified.append(.init(remoteIdentifier: row.remoteIdentifier, profile: profile))
        }
        guard Set(verified.map { $0.profile.constraints.uuid }).count == verified.count else {
            throw NativeProfileCreationError.inventoryRejected
        }
        guard verified.count <= 1 else { throw NativeProfileCreationError.reconciliationRequired }
        return verified.first
    }

    private func finish(_ record: NativeProfileCreationRecord?, observed: VerifiedObservation,
                        owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws -> NativeProfileCreationResult {
        try Task.checkCancellation()
        guard var record else { return .init(operationID: nil, profile: observed.profile) }
        let digest = NativeSigningIdentityOwner.hash(Data(observed.remoteIdentifier.utf8))
        if record.phase == .recorded {
            guard record.remoteIdentifierDigest == digest, record.profileUUID == observed.profile.constraints.uuid,
                  record.cmsSHA256 == observed.profile.cmsSHA256 else { throw NativeProfileCreationError.reconciliationRequired }
        } else {
            record.phase = .recorded; record.remoteIdentifierDigest = digest
            record.profileUUID = observed.profile.constraints.uuid; record.cmsSHA256 = observed.profile.cmsSHA256
            try store.recordObservation(record, owner: owner, request: request)
        }
        return .init(operationID: record.id, profile: observed.profile)
    }
}
