import Foundation

/// Small, secret-adjacent ownership journal. Persist only in device-only Keychain,
/// never preferences. A selected team is a UI hint, NOT proof of authorization.
struct AppleAccountResumeJournal: Codable, Equatable, Sendable {
    var schema = 1
    var selectedReference: UUID?
    var selectedTeamIdentifier: String?
    var pendingInsert: UUID?
    var pendingDeletions: Set<UUID> = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, selectedReference, selectedTeamIdentifier, pendingInsert, pendingDeletions
    }

    func validate() throws {
        guard schema == 1 else { throw AppleAccountSessionRepositoryError.unsupportedJournalVersion }
        let ownedCount = pendingDeletions.count + (selectedReference == nil ? 0 : 1) + (pendingInsert == nil ? 0 : 1)
        guard ownedCount <= 16,
              selectedReference != nil || selectedTeamIdentifier == nil,
              pendingInsert == nil || selectedReference == nil,
              selectedReference.map({ !pendingDeletions.contains($0) }) ?? true,
              pendingInsert.map({ !pendingDeletions.contains($0) }) ?? true else {
            throw AppleAccountSessionRepositoryError.invalidJournal
        }
        if let team = selectedTeamIdentifier {
            guard Self.validTeamIdentifier(team) else { throw AppleAccountSessionRepositoryError.invalidJournal }
        }
    }

    static func validTeamIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

enum AppleAccountSessionRepositoryError: Error, Equatable {
    case unsupportedJournalVersion
    case invalidJournal
    case sessionAlreadySelected
    case staleReference
    case missingSelectedSession
    case signOutIncomplete
}

protocol AppleAccountResumeJournalStorage: Sendable {
    func readJournal() throws -> AppleAccountResumeJournal?
    /// Atomic replacement (old or new record), never partial bytes.
    func writeJournal(_ journal: AppleAccountResumeJournal) throws
}

protocol AppleAccountRecoverableSessionStorage: AppleAccountSessionStorage {
    func readSession(reference: UUID) throws -> Data?
}

/// Durable storage value exclusively owned by the authentication worker actor
/// (or standalone repository facade). Insert can leave a journaled reservation
/// when it throws, so this value must not
/// conform to AppleAccountSessionStorage's no-write-on-throw contract.
///
/// One repository instance must be the sole writer for this journal/service in
/// the primary app process. This is NOT cross-process locking or a multi-account
/// database. No extensions/guests may write it. Do not construct a repository
/// facade alongside a coordinator that already owns this namespace.
struct AppleAccountSessionPersistence<Sessions: AppleAccountRecoverableSessionStorage, Journal: AppleAccountResumeJournalStorage>: Sendable {
    struct ResumeCandidate: Equatable, Sendable {
        let reference: UUID
        let encodedSession: Data
        let selectedTeamHint: String?
    }

    private let sessions: Sessions
    private let journalStore: Journal
    private var signOutRequested = false

    init(sessions: Sessions, journal: Journal) {
        self.sessions = sessions
        self.journalStore = journal
    }

    /// Does not decode SDK bytes, restore authentication or authorize a team.
    /// Caller must use the SDK codec + fresh anisette + Apple revalidation.
    func recoverCandidate() throws -> ResumeCandidate? {
        guard !signOutRequested else { throw AppleAccountSessionRepositoryError.signOutIncomplete }
        let journal = try recoverCleanup()
        guard let reference = journal.selectedReference else { return nil }
        guard let data = try sessions.readSession(reference: reference) else {
            // Do not silently replace a dangling reference with a different login.
            throw AppleAccountSessionRepositoryError.missingSelectedSession
        }
        return ResumeCandidate(reference: reference, encodedSession: data,
                               selectedTeamHint: journal.selectedTeamIdentifier)
    }

    /// UUID reservation precedes insert. Death/failure before selection leaves a
    /// tracked orphan that recovery deletes; after selection it is a candidate.
    /// Bytes must already have passed the allowlisted SDK codec.
    @discardableResult
    func commitNewSession(_ encodedSession: Data) throws -> UUID {
        guard !signOutRequested else { throw AppleAccountSessionRepositoryError.signOutIncomplete }
        var journal = try recoverCleanup()
        guard journal.selectedReference == nil else {
            throw AppleAccountSessionRepositoryError.sessionAlreadySelected
        }
        let reference = UUID()
        journal.pendingInsert = reference
        try journalStore.writeJournal(journal)
        try sessions.insertSession(encodedSession, reference: reference)
        journal.pendingInsert = nil
        journal.selectedReference = reference
        try journalStore.writeJournal(journal)
        return reference
    }

    /// The adapter must first authorize this team against a fresh portal result
    /// and require explicit user selection. The saved value is only a resume hint.
    func saveSelectedTeamHint(_ identifier: String, reference: UUID) throws {
        guard !signOutRequested else { throw AppleAccountSessionRepositoryError.signOutIncomplete }
        guard AppleAccountResumeJournal.validTeamIdentifier(identifier) else {
            throw AppleAccountSessionRepositoryError.invalidJournal
        }
        var journal = try recoverCleanup()
        guard journal.selectedReference == reference else {
            throw AppleAccountSessionRepositoryError.staleReference
        }
        journal.selectedTeamIdentifier = identifier
        try journalStore.writeJournal(journal)
    }

    /// Persist deselection/deletion intent BEFORE touching session bytes. Failure
    /// of that initial write means sign-out is NOT durable; surface/retry it.
    /// The owning coordinator must invalidate UI/tasks/context before this call.
    mutating func signOut() throws {
        signOutRequested = true
        var journal = try load()
        if let reference = journal.selectedReference { journal.pendingDeletions.insert(reference) }
        if let reference = journal.pendingInsert { journal.pendingDeletions.insert(reference) }
        journal.selectedReference = nil
        journal.selectedTeamIdentifier = nil
        journal.pendingInsert = nil
        try journalStore.writeJournal(journal)
        _ = try recoverCleanup()
        signOutRequested = false
    }

    private func load() throws -> AppleAccountResumeJournal {
        let journal = try journalStore.readJournal() ?? AppleAccountResumeJournal()
        try journal.validate()
        return journal
    }

    /// A failed delete or journal rewrite preserves ownership on disk. Repeating
    /// an exact deletion is safe because the session store treats not-found as OK.
    private func recoverCleanup() throws -> AppleAccountResumeJournal {
        var journal = try load()
        if let reference = journal.pendingInsert {
            journal.pendingInsert = nil
            journal.pendingDeletions.insert(reference)
            try journalStore.writeJournal(journal)
        }
        for reference in Array(journal.pendingDeletions) {
            try sessions.deleteSession(reference: reference)
            journal.pendingDeletions.remove(reference)
            try journalStore.writeJournal(journal)
        }
        return journal
    }
}

/// Standalone worker facade for recovery clients/tests. Production authentication
/// must instead let the coordinator exclusively own its persistence value. Never
/// instantiate both against the same namespace at the same time.
actor AppleAccountSessionRepository<Sessions: AppleAccountRecoverableSessionStorage, Journal: AppleAccountResumeJournalStorage> {
    typealias ResumeCandidate = AppleAccountSessionPersistence<Sessions, Journal>.ResumeCandidate
    private var persistence: AppleAccountSessionPersistence<Sessions, Journal>

    init(sessions: Sessions, journal: Journal) {
        persistence = AppleAccountSessionPersistence(sessions: sessions, journal: journal)
    }

    func recoverCandidate() throws -> ResumeCandidate? { try persistence.recoverCandidate() }
    @discardableResult
    func commitNewSession(_ data: Data) throws -> UUID { try persistence.commitNewSession(data) }
    func saveSelectedTeamHint(_ identifier: String, reference: UUID) throws {
        try persistence.saveSelectedTeamHint(identifier, reference: reference)
    }
    func signOut() throws { try persistence.signOut() }
}
