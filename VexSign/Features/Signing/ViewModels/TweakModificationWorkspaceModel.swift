// MARK: - Tweak modification workspace state
//
// All archive parsing, Mach-O inspection and signing is delegated to services.
// The model holds only value snapshots for the SwiftUI screens.

import Foundation
import SwiftUI
import NimbleExtensions

@MainActor
final class TweakModificationWorkspaceModel: ObservableObject {
    @Published private(set) var inspections: [TweakPackageInspection] = []
    @Published private(set) var plan: InjectionPlan?
    @Published private(set) var operationReport: InjectionOperationReport?
    @Published private(set) var verificationReport: SigningVerificationReport?
    @Published private(set) var profiles: [ModificationProfile] = []
    @Published private(set) var isBusy = false
    @Published var message: String?

    private let store: ModificationProfileStore
    private var activeRequestID: String?
    private var activeConfigurations: [InjectionConfiguration] = []

    init(store: ModificationProfileStore = ModificationProfileStore()) {
        self.store = store
        _ = try? store.prune(against: []) // try? ok: a missing profile file is an empty library
        reloadProfiles()
    }

    func reloadProfiles() {
        do { profiles = try store.load() }
        catch { message = error.localizedDescription }
    }

    func inspect(tweaks: [ManagedTweak], using tweakModel: TweakWorkspaceModel) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        var found: [TweakPackageInspection] = []
        for tweak in tweaks.prefix(32) {
            guard let version = tweak.activeVersion else { continue }
            for component in version.components where component.isEnabled && component.fileType == .deb {
                let url = tweakModel.fileURL(forTweak: tweak, version: version, component: component)
                guard TweakPackageInspector.artifactExists(at: url) else { continue }
                do {
                    found.append(try await TweakPackageInspector.inspect(fileAt: url))
                } catch {
                    message = String.localized("Could not inspect %@: %@", arguments: component.fileName, error.localizedDescription)
                }
            }
        }
        inspections = found
    }

    func buildPlan(
        app: LibraryAppRecord,
        tweaks: [ManagedTweak],
        tweakModel: TweakWorkspaceModel,
        signing: SigningWorkspaceModel
    ) {
        guard !tweaks.isEmpty else {
            message = .localized("Select at least one imported tweak before building a plan.")
            return
        }
        let contents = signing.bundleContents(app: app)
        let bundleID = app.identifier ?? contents?.infoPlist["CFBundleIdentifier"] as? String
        var targets: [InjectionTarget] = []
        if let bundleID {
            targets.append(InjectionTarget(
                id: "main", displayName: app.name ?? bundleID, bundleIdentifier: bundleID,
                executableName: app.name, isMain: true
            ))
        }
        for plugin in signing.applicationExtensionNames(app: app) {
            targets.append(InjectionTarget(
                id: "extension-\(plugin)", displayName: plugin,
                bundleIdentifier: bundleID.map { "\($0).\(plugin)" },
                executableName: plugin, isMain: false
            ))
        }

        let byPackage = Dictionary(inspections.compactMap { inspection -> (String, TweakPackageInspection)? in
            guard let id = inspection.packageID?.lowercased() else { return nil }
            return (id, inspection)
        }, uniquingKeysWith: { first, _ in first })

        var configurations: [InjectionConfiguration] = []
        var binaryFindings: [InjectionFinding] = []
        for tweak in tweaks {
            guard let version = tweak.activeVersion else { continue }
            let packageID = tweak.name.lowercased()
            let inspection = byPackage[packageID]
            let filter = inspection?.filters.values.first
            let configuration = InjectionConfiguration.from(
                packageID: packageID,
                version: version.label,
                enabled: tweak.isEnabled,
                filter: filter,
                installPath: Options.InjectPath.executable_path.rawValue,
                provenance: filter == nil ? "Explicit selection in modification workspace" : "Package filter plist"
            )
            configurations.append(configuration)

            for component in version.components where component.isEnabled && component.fileType != .deb {
                let fileURL = tweakModel.fileURL(forTweak: tweak, version: version, component: component)
                let binaryURL: URL?
                if component.fileType == .framework {
                    binaryURL = Bundle(url: fileURL)?.executableURL
                } else if component.fileType == .dylib {
                    binaryURL = fileURL
                } else { binaryURL = nil }
                guard let binaryURL else { continue }
                let result = TweakCompatibility.evaluate(binary: MachOInspector.inspect(fileAt: binaryURL))
                binaryFindings += result.map {
                    InjectionFinding(code: "binary-\($0.code)", severity: $0.isBlocking ? .blocking : .advisory, detail: $0.message)
                }
            }
        }

        activeConfigurations = configurations
        plan = InjectionPlanner.makePlan(input: InjectionPlanningInput(
            appIdentifier: bundleID,
            targets: targets,
            inspections: inspections,
            configurations: configurations,
            binaryFindings: binaryFindings,
            hookRuntimeAvailable: true
        ))
    }

    func apply(
        plan: InjectionPlan,
        app: LibraryAppRecord,
        tweaks: [ManagedTweak],
        tweakModel: TweakWorkspaceModel,
        signing: SigningWorkspaceModel
    ) {
        guard plan.canApply else {
            message = .localized("Resolve every blocking finding before applying this plan. Nothing was signed.")
            record(plan: plan, status: .failed, completed: [], failed: "planNotApplicable")
            return
        }
        let requestID = UUID().uuidString
        activeRequestID = requestID
        isBusy = true
        verificationReport = nil

        let specs = tweaks.compactMap { tweakModel.injectionSpec(for: $0, availableAppex: signing.applicationExtensionNames(app: app)) }
        guard !specs.isEmpty else {
            isBusy = false
            message = .localized("No importable tweak files were resolved. The original application was not modified.")
            return
        }

        signing.applyModification(
            app,
            specs: specs,
            configurations: activeConfigurations,
            injectIntoExtensions: plan.targets.contains { !$0.isMain },
            requestID: requestID,
            onVerificationReport: { [weak self] report in
                self?.verificationReport = report
            },
            completion: { [weak self] result in
                guard let self, self.activeRequestID == requestID else { return }
                self.activeRequestID = nil
                self.isBusy = false
                switch result {
                case .success(let output):
                    self.record(
                        plan: plan, status: .applied,
                        completed: plan.steps.map(\.id), failed: nil
                    )
                    let inspected = Self.loadCommandPaths(in: output.bundleURL)
                    if inspected.isEmpty {
                        self.message = .localized("Signing finished, but the output bundle could not be re-inspected. It is not presented as a verified tweak build.")
                    } else {
                        self.message = String.localized(
                            "Signing finished. Final executable load commands: %@. Runtime behaviour was not tested.",
                            arguments: inspected.joined(separator: ", ")
                        )
                    }
                case .failure(let error):
                    self.record(plan: plan, status: .failed, completed: [], failed: error.localizedDescription)
                    self.message = error.localizedDescription
                }
            }
        )
    }

    func cancel() {
        guard activeRequestID != nil, let plan else { return }
        // The signing owner stops the run and cleans its temporary working copy.
        // Forgetting the request id makes any late completion a no-op, so a
        // cancelled run can never be presented as a successful modification.
        activeRequestID = nil
        isBusy = false
        record(plan: plan, status: .cancelled, completed: [], failed: "cancelledByUser")
        message = .localized("Modification stopped. The original import is unchanged; the temporary signing copy is cleaned up by the signing pipeline.")
    }

    func saveProfile(name: String, app: LibraryAppRecord, tweaks: [ManagedTweak], plan: InjectionPlan) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entries = tweaks.compactMap { tweak -> ModificationProfileEntry? in
            guard let version = tweak.activeVersion else { return nil }
            return ModificationProfileEntry(
                tweakID: tweak.id,
                versionID: version.id,
                enabled: tweak.isEnabled,
                injectionPath: plan.steps.isEmpty ? nil : Options.InjectPath.executable_path.rawValue,
                injectionFolder: nil
            )
        }
        do {
            let profile = ModificationProfile(
                name: name,
                appBundleIdentifier: app.identifier ?? plan.appIdentifier ?? "",
                entries: entries
            )
            profiles = try store.upsert(profile)
            message = String.localized("Saved modification profile “%@”.", arguments: name)
        } catch { message = error.localizedDescription }
    }

    func deleteProfile(_ profile: ModificationProfile) {
        do { profiles = try store.remove(id: profile.id) }
        catch { message = error.localizedDescription }
    }

    func duplicateProfile(_ profile: ModificationProfile) {
        do {
            profiles = try store.upsert(profile.duplicating(name: profile.name + " Copy"))
        } catch { message = error.localizedDescription }
    }

    /// Exposed read-only so the toolbar can forward cancellation to the owner.
    var activeRequestIDForCancellation: String? { activeRequestID }

    private func record(plan: InjectionPlan, status: InjectionOperationReport.Status, completed: [String], failed: String?) {
        operationReport = InjectionOperationReport(
            id: UUID().uuidString,
            planID: plan.id,
            status: status,
            completedSteps: completed,
            failedStep: failed,
            findingDetails: plan.findings.map(\.detail),
            finishedAt: Date()
        )
    }

    nonisolated private static func loadCommandPaths(in bundle: URL?) -> [String] {
        guard let bundle, let executable = Bundle(url: bundle)?.executableURL else { return [] }
        return MachOReader.dylibs(forExecutableAt: executable).filter {
            $0.hasPrefix("@executable_path") || $0.hasPrefix("@rpath")
        }
    }
}
