import SwiftUI

/// Disposable fixture only. Never submits an uninstall or treats queue admission as a restore.
struct FixtureSlotView: View {
    @EnvironmentObject private var services: AppContainer
    private let app: AppInfoPresentable?
    private let entry: FixtureRecoveryEntry?
    init(app: AppInfoPresentable) { self.app = app; entry = nil }
    init(entry: FixtureRecoveryEntry) { self.entry = entry; app = nil }
    private var anchorID: String? { app?.workspaceIdentity ?? entry?.id }
    private var anchorUUID: String? { app?.uuid ?? entry?.uuid }
    @ObservedObject private var locks = AppLockManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var candidateID = ""
    @State private var confirmRebind = false
    @State private var record: FixtureSlotRecord?
    @State private var input = ""
    @State private var message = ""
    @State private var eligible = false
    @State private var confirm = false
    @State private var confirmKeptFixture = false
    @State private var confirmRetry = false

    var body: some View {
        Form {
            Section("Manual slot rehearsal") {
                Text("Only the disposable VexSign marker fixture is supported. A library IPA alone is not an app-data backup.")
                if !message.isEmpty { Text(message) }
            }
            if accessAllowed, scenePhase == .active, !eligible, let record {
                Section("Read-only marker backup") {
                    Text("The saved marker remains available, but the selected copy cannot be used for installation or restore.")
                    Text(record.backup.marker.uuidString).textSelection(.enabled)
                    Picker("Replacement signed fixture", selection: $candidateID) {
                        Text("Select a copy").tag("")
                        ForEach(services.workspace.snapshot.signedApps.filter { $0.identifier == record.backup.bundle && $0.workspaceIdentity != (record.activeCopyID ?? record.copyID) }, id: \.workspaceIdentity) { copy in
                            if let id = copy.workspaceIdentity {
                                Text("\(copy.name ?? record.backup.bundle) · \(copy.uuid?.prefix(8) ?? "")").tag(id)
                            }
                        }
                    }
                    Button("Review replacement binding") { confirmRebind = true }.disabled(candidateID.isEmpty)
                        .confirmationDialog("Bind the saved marker to this re-signed copy?", isPresented: $confirmRebind) {
                            Button("Rebind and invalidate old replies") { rebind() }
                        } message: { Text("The bundle and signing team must match. Nothing will be installed or removed.") }
                }
            }
            if eligible && accessAllowed && scenePhase == .active {
                if record == nil || record?.phase == .restored {
                    if record?.phase == .restored { Text("The fixture reported reading the restored marker.") }
                    packetInput
                    Button("Save fixture backup") { perform { binding, previous in
                        guard previous == nil || previous?.phase == .restored else { throw CocoaError(.fileWriteFileExists) }
                        let packet = try FixtureSlotPacket.parse(input)
                        guard packet.kind == .backup, packet.challenge == nil, packet.bundle == binding.bundle,
                              packet.profile == binding.profile else { throw CocoaError(.fileReadCorruptFile) }
                        try FixtureSlotStorage.save(.init(copyID: previous?.copyID ?? binding.copy, backup: packet, phase: .rehearsal, challenge: UUID(), signingTeam: binding.team, activeCopyID: previous?.activeCopyID, anchorUUID: anchorUUID, activeUUID: previous?.activeUUID))
                    } }
                } else if let record {
                    if record.phase == .ready {
                        Text("The fixture rehearsed importing the marker. This does not cover any other app or data.")
                        Button("Plan manual deactivation", role: .destructive) { confirm = true }
                    } else {
                        if record.phase == .removalPlanned {
                            Text("Removal planned, not confirmed. Remove only the disposable fixture yourself. When ready, reinstall this exact signed copy and return the restore packet to the fixture.")
                            Button("Queue reinstall of fixture") { perform { _, current in
                                guard var next = current else { throw CocoaError(.fileReadNoSuchFile) }
                                let report = try services.installation.readiness(for: try target(current))
                                if let blocker = FixtureSlotRecord.reinstallBlocker(report) {
                                    message = blocker
                                    return
                                }
                                try next.beginReinstall()
                                try FixtureSlotStorage.save(next) // persist before crossing the installer boundary
                                self.record = next
                                let submission = try services.installation.installWithoutSigning(try target(current))
                                guard submission == .submittedForInstallation else {
                                    message = "Not submitted as a standalone installation. Check the selected installation method."
                                    return
                                }
                                try next.acknowledgeSubmission()
                                try FixtureSlotStorage.save(next)
                            } }
                            Button("Cancel plan — I kept the original fixture") { confirmKeptFixture = true }
                                .confirmationDialog("Is the original fixture still installed with its marker?", isPresented: $confirmKeptFixture) {
                                    Button("Yes, return to rehearsal") { perform { _, current in
                                        guard var next = current else { throw CocoaError(.fileReadNoSuchFile) }
                                        try next.cancelUnsubmittedPlan()
                                        try FixtureSlotStorage.save(next)
                                    } }
                                } message: { Text("Your backup is kept. The old restore packet is invalidated. If you removed the fixture, continue recovery instead.") }
                        } else if record.phase == .awaitingFixture || record.phase == .reinstallUncertain {
                            if record.phase == .awaitingFixture {
                                Text("Install submitted. Open the fixture and return its restore reply; installation is not yet verified.")
                            } else {
                                Text("An install attempt was recorded, but submission is not confirmed. Check the device and install queue before retrying.")
                            }
                            Button("Review manual retry") { confirmRetry = true }
                                .confirmationDialog("Allow a new install attempt?", isPresented: $confirmRetry) {
                                    Button("I checked the device and queue; enable retry") { perform { _, current in
                                        guard var next = current else { throw CocoaError(.fileReadNoSuchFile) }
                                        try next.allowManualRetry(); try FixtureSlotStorage.save(next)
                                    } }
                                } message: { Text("Only enable retry if no install is pending. This replaces the restore request; it does not submit another install.") }
                        }
                        if let text = try? record.backup.with(record.phase == .rehearsal ? .rehearse : .restore, challenge: record.challenge).text() { // try? ok: omit the share action if the request cannot be encoded
                            ShareLink(item: text) { Text("Share request for fixture") }
                            Text(text).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        packetInput
                        Button("Check fixture reply") { perform { _, current in
                            guard var next = current else { throw CocoaError(.fileReadNoSuchFile) }
                            try next.accept(FixtureSlotPacket.parse(input)); try FixtureSlotStorage.save(next)
                        } }
                    }
                }
            }
        }
        .navigationTitle("Fixture slot manager")
        .task { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .confirmationDialog("Plan removal of the disposable fixture?", isPresented: $confirm) {
            Button("Save recovery plan", role: .destructive) { perform { _, current in
                guard var next = current else { throw CocoaError(.fileReadNoSuchFile) }
                let route = try services.installation.readiness(for: try target(current))
                guard let bundle = try target(current).bundleURL else { throw CocoaError(.fileReadNoSuchFile) }
                try next.planRemoval(route: route, verification: DirectInstaller.verify(directory: bundle))
                try FixtureSlotStorage.save(next)
            } }
        } message: { Text("Keep this signed copy in VexSign. No uninstall command will be sent or retried.") }
    }

    private var packetInput: some View {
        TextField("Paste JSON from fixture", text: $input, axis: .vertical)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    private func unlocked(_ copy: AppInfoPresentable) -> Bool {
        guard let uuid = copy.uuid else { return false }
        return permitted(uuid)
    }
    private func permitted(_ uuid: String?) -> Bool {
        guard let uuid, !locks.isLocked, !locks.hiddenAppUUIDs.contains(uuid) || locks.isRevealingHiddenApps else { return false }
        return !locks.isAppLocked(uuid) || locks.isSessionUnlocked(uuid)
    }
    private var accessAllowed: Bool {
        guard permitted(anchorUUID) else { return false }
        if let entry, record?.anchorUUID != entry.uuid { return false }
        if let lockID = record?.activeUUID ?? entry?.activeUUID, !permitted(lockID) { return false }
        if let id = record?.activeCopyID, let copy = services.workspace.snapshot.signedApps.first(where: { $0.workspaceIdentity == id }) {
            return unlocked(copy)
        }
        return true
    }
    private func target(_ current: FixtureSlotRecord?) throws -> AppInfoPresentable {
        guard permitted(anchorUUID) else { throw CocoaError(.fileReadNoPermission) }
        if let lockID = current?.activeUUID, !permitted(lockID) { throw CocoaError(.fileReadNoPermission) }
        if current?.activeCopyID == nil, let app { return app }
        guard let id = current?.activeCopyID ?? anchorID else { throw CocoaError(.fileReadNoSuchFile) }
        guard let copy = services.workspace.snapshot.signedApps.first(where: { $0.workspaceIdentity == id }) else { throw CocoaError(.fileReadNoSuchFile) }
        guard unlocked(copy) else { throw CocoaError(.fileReadNoPermission) }
        return copy
    }
    private func refresh() {
        record = nil; eligible = false
        do {
            guard permitted(anchorUUID), let id = anchorID else { throw CocoaError(.fileReadNoPermission) }
            record = try FixtureSlotStorage.load(id)
            perform { _, _ in }
        } catch { message = error.localizedDescription }
    }
    private func rebind() {
        do {
            guard permitted(anchorUUID), let anchor = anchorID, var next = try FixtureSlotStorage.load(anchor),
                  next.challenge == record?.challenge,
                  let candidate = services.workspace.snapshot.signedApps.first(where: { $0.workspaceIdentity == candidateID }),
                  unlocked(candidate), let url = candidate.bundleURL else { throw CocoaError(.fileReadNoPermission) }
            let oldTeam: String
            if let team = next.signingTeam { oldTeam = team }
            else {
                let old = try FixtureSlotStorage.binding(try target(next), forHistoricalReview: true)
                guard old.profile == next.backup.profile, old.bundle == next.backup.bundle else { throw CocoaError(.fileReadCorruptFile) }
                oldTeam = old.team
            }
            guard accessAllowed else { throw CocoaError(.fileReadNoPermission) }
            let replacement = try FixtureSlotStorage.binding(candidate)
            let verification = DirectInstaller.verify(directory: url)
            guard verification.isSigned, !verification.hasBlockingIssues else { throw CocoaError(.fileReadCorruptFile) }
            try next.rebind(to: replacement, previousTeam: oldTeam)
            next.anchorUUID = anchorUUID; next.activeUUID = candidate.uuid
            try FixtureSlotStorage.save(next)
            candidateID = ""; refresh()
        } catch { message = error.localizedDescription }
    }
    private func perform(_ body: (FixtureSlotBinding, FixtureSlotRecord?) throws -> Void) {
        do {
            guard permitted(anchorUUID), let id = anchorID else { throw CocoaError(.fileReadNoPermission) }
            var current = try FixtureSlotStorage.load(id)
            eligible = false; record = current
            let binding = try FixtureSlotStorage.binding(try target(current))
            if entry != nil && current?.anchorUUID != anchorUUID { throw CocoaError(.fileReadNoPermission) }
            guard current.map({ $0.backup.bundle == binding.bundle && $0.backup.profile == binding.profile }) ?? true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if var legacy = current, legacy.anchorUUID == nil, let app, let uuid = app.uuid {
                legacy.anchorUUID = uuid
                if legacy.activeCopyID != nil { legacy.activeUUID = try target(legacy).uuid }
                try FixtureSlotStorage.save(legacy); current = legacy
            }
            eligible = true; message = ""
            try body(binding, current)
            record = try FixtureSlotStorage.load(id); input = ""
        } catch { message = error.localizedDescription }
    }
}
