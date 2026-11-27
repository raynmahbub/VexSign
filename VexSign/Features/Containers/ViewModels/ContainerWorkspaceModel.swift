// MARK: - Container workspace state
//
// Views only bind to published values. Storage, archive validation, hand-off and
// task reporting happen in the injected services.

import Foundation
import SwiftUI
import Combine
import NimbleExtensions

@MainActor
final class ContainerWorkspaceModel: ObservableObject {
    @Published private(set) var containers: [AppContainerRecord] = []
    @Published private(set) var selected: AppContainerRecord?
    @Published private(set) var libraryApps: [LibraryAppRecord] = []
    @Published private(set) var usage: [String: ContainerUsage] = [:]
    @Published private(set) var recoveryReport: ContainerRecoveryReport = .empty
    @Published private(set) var isBusy = false
    @Published var message: String?
    @Published var error: String?
    @Published var searchText = ""

    private let store: ContainerStore
    private let archives: ContainerArchiveService
    private let handoff: ContainerURLHandoff
    private let tasks: ContainerTaskReporter
    private let workspaceProvider: @MainActor () -> WorkspaceSnapshot

    init(
        store: ContainerStore = ContainerStore(),
        archives: ContainerArchiveService? = nil,
        handoff: ContainerURLHandoff = ContainerURLHandoff(),
        tasks: ContainerTaskReporter = ContainerTaskReporter(),
        workspaceProvider: @escaping @MainActor () -> WorkspaceSnapshot = { .empty }
    ) {
        self.store = store
        self.archives = archives ?? ContainerArchiveService(store: store)
        self.handoff = handoff
        self.tasks = tasks
        self.workspaceProvider = workspaceProvider
    }

    var filtered: [AppContainerRecord] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return containers }
        return containers.filter {
            $0.displayName.lowercased().contains(needle)
                || ($0.application?.bundleIdentifier?.lowercased().contains(needle) ?? false)
                || ($0.detail.lowercased().contains(needle))
        }
    }

    func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let recovery = try await store.prepare()
            recoveryReport = recovery
            containers = try await store.list()
            var measured: [String: ContainerUsage] = [:]
            for container in containers {
                measured[container.id] = try? await store.usage(id: container.id) // try? ok: unavailable size falls back to declared resource bytes
            }
            usage = measured
            libraryApps = workspaceProvider().apps
            if let selected {
                self.selected = try? await store.record(id: selected.id) // try? ok: a stale detail is cleared when its container disappears
            }
            error = recovery.actionableDescription
        } catch { self.error = error.localizedDescription }
    }

    func create(name: String, detail: String) async -> AppContainerRecord? {
        isBusy = true
        defer { isBusy = false }
        do {
            let record = try await store.create(displayName: name, detail: detail)
            await load()
            message = String.localized("Created container %@.", arguments: record.displayName)
            return record
        } catch { self.error = error.localizedDescription; return nil }
    }

    func rename(_ container: AppContainerRecord, to name: String) async {
        await perform { try await store.rename(id: container.id, to: name) }
    }

    func updateDetail(_ container: AppContainerRecord, detail: String) async {
        await perform { try await store.update(id: container.id, detail: detail) }
    }

    func setPreference(_ container: AppContainerRecord, key: String, value: ContainerPreferenceValue?) async {
        await perform { try await store.setPreference(id: container.id, key: key, value: value) }
    }

    func associate(_ container: AppContainerRecord, app: LibraryAppRecord?) async {
        let reference: ContainerAppReference?
        if let app {
            reference = ContainerAppReference(
                recordID: app.recordID, uuid: app.uuid, name: app.name,
                bundleIdentifier: app.identifier ?? app.originalIdentifier,
                version: app.version, sourceURL: app.source?.absoluteString,
                certificateID: app.certificateID
            )
        } else { reference = nil }
        await perform { try await store.associate(id: container.id, application: reference) }
    }

    func addResource(_ container: AppContainerRecord, from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await perform {
            try await store.addResource(id: container.id, from: url,
                                        relativePath: url.lastPathComponent)
        }
    }

    func removeResource(_ container: AppContainerRecord, path: String) async {
        await perform { try await store.removeResource(id: container.id, relativePath: path) }
    }

    func duplicate(_ container: AppContainerRecord, name: String) async {
        await perform { try await store.duplicate(id: container.id, displayName: name) }
    }

    func delete(_ container: AppContainerRecord) async {
        do {
            isBusy = true
            try await store.delete(id: container.id)
            if selected?.id == container.id { selected = nil }
            await load()
            message = .localized("The container was deleted.")
        } catch { self.error = error.localizedDescription }
        isBusy = false
    }

    func export(_ container: AppContainerRecord, password: String?) async -> ContainerExport? {
        isBusy = true
        let taskID = await tasks.begin(title: container.displayName,
                                       subtitle: .localized("Exporting container"), subjectID: container.id)
        await tasks.transition(id: taskID, to: .extracting, progress: 0.2)
        defer { isBusy = false }
        do {
            let result = try await archives.export(id: container.id, password: password)
            await tasks.transition(id: taskID, to: .completed, progress: 1)
            message = .localized("The container export is ready to save.")
            return result
        } catch {
            await tasks.transition(id: taskID, to: .failed, error: error.localizedDescription)
            self.error = error.localizedDescription
            return nil
        }
    }

    func exportDocument(_ container: AppContainerRecord, password: String?) async -> ContainerArchiveFile? {
        let document = await archives.exportDocument(id: container.id, password: password)
        if document == nil, error == nil { error = .localized("The container export could not be prepared.") }
        return document
    }

    func restore(file: URL, password: String?, replaceID: String?) async {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        isBusy = true
        let taskID = await tasks.begin(title: .localized("Restore container"),
                                       subtitle: .localized("Validating archive"), subjectID: nil)
        await tasks.transition(id: taskID, to: .verifying, progress: 0.2)
        defer { isBusy = false }
        do {
            let authorization: ContainerRestoreAuthorization = replaceID.map { .replace(id: $0) } ?? .createNew
            let restored = try await archives.restore(file: file, password: password,
                                                       authorization: authorization)
            await tasks.transition(id: taskID, to: .completed, progress: 1)
            await load()
            selected = restored
            message = String.localized("Restored container %@.", arguments: restored.displayName)
        } catch {
            await tasks.transition(id: taskID, to: .failed, error: error.localizedDescription)
            self.error = error.localizedDescription
        }
    }

    func preview(file: URL, password: String?) async -> ContainerExportManifest? {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do { return try await archives.inspect(file: file, password: password) }
        catch { self.error = error.localizedDescription; return nil }
    }

    func handoff(route: ContainerHandoffRoute, container: AppContainerRecord) async {
        guard let bundle = container.application?.bundleIdentifier else {
            error = .localized("Associate an application record before requesting a hand-off.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        let outcome = await handoff.handoff(route: route, bundleIdentifier: bundle)
        message = outcome.message
        if outcome != .openedUnverified && outcome != .embeddedHostRequested { error = outcome.message }
    }

    private func perform(_ operation: () async throws -> AppContainerRecord) async {
        do {
            isBusy = true
            let record = try await operation()
            selected = record
            await load()
            error = nil
        } catch { self.error = error.localizedDescription }
        isBusy = false
    }
}
