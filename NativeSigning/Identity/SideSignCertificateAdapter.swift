import Foundation
import SideSign

protocol SideSignPreparedCSRPortal: SideSignProvisioningPortal {
    func submitPreparedDevelopmentCSR(_ submission: NativeSigningCSRSubmission, team: Team,
                                      session: Session) async throws -> NativeSigningCertificateObservation?
}

struct SideSignCertificateAdapter<Portal: SideSignProvisioningPortal>: Sendable {
    let portal: Portal

    func authorize(encodedSession: Data, headers: AnisetteData, teamIdentifier: String, now: Date,
                   checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> (session: Session, team: Team) {
        do {
            try await checkCurrent()
            let auth = try SideSignSessionCodec.decodeForRevalidation(encodedSession, freshAnisetteData: headers, now: now)
            let account = try await portal.fetchAccount(session: auth.session)
            try await checkCurrent()
            guard account.identifier == auth.account.identifier,
                  account.appleID.lowercased() == auth.account.appleID.lowercased() else {
                throw NativeSigningIdentityError.contextChanged
            }
            let teams = try await portal.fetchTeams(for: account, session: auth.session)
            try await checkCurrent()
            guard teams.count <= 100, Set(teams.map(\.identifier)).count == teams.count,
                  let team = teams.first(where: { $0.identifier == teamIdentifier }), team.type == .free,
                  team.account.map({ $0.identifier == account.identifier }) ?? true else {
                throw NativeSigningIdentityError.contextChanged
            }
            return (auth.session, team)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeSigningIdentityError { throw safe }
            throw NativeSigningIdentityError.certificateRequestFailed
        }
    }

    func observations(team: Team, session: Session,
                      checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> [NativeSigningCertificateObservation] {
        do {
            try await checkCurrent()
            let certificates = try await portal.fetchCertificates(for: team, session: session)
            try await checkCurrent()
            guard certificates.count <= 1000 else { throw NativeSigningIdentityError.certificateRejected }
            return try certificates.map {
                guard let id = $0.identifier, !id.isEmpty, id.utf8.count <= 256 else {
                    throw NativeSigningIdentityError.reconciliationRequired
                }
                return NativeSigningCertificateObservation(identifier: id, certificateDER: $0.rawDER)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeSigningIdentityError { throw safe }
            throw NativeSigningIdentityError.reconciliationRequired
        }
    }
}
