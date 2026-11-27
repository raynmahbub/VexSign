// MARK: - Tweak modification workspace
//
// Every row below is backed by real package inspection, the real tweak library,
// a deterministic plan or the signing pipeline's own verification report. No
// progress value or success state is simulated here.

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers
import NimbleExtensions

struct TweakModificationWorkspaceView: View {
    @EnvironmentObject private var services: AppContainer
    @StateObject private var model = TweakModificationWorkspaceModel()
    @State private var selectedAppID: String?
    @State private var selectedTweakIDs: Set<UUID> = []
    @State private var profileName = ""
    @State private var isImportingPackage = false
    @State private var expandedPackage: String?

    var body: some View {
        NBNavigationView(String.localized("Modify App with Tweaks"), displayMode: .inline) {
            List {
                _packagesSection
                _applicationSection
                _planSection
                _resultsSection
                _profilesSection
            }
            .listStyle(.insetGrouped)
            .dismissableKeyboard()
            .overlay { if model.isBusy { ProgressView().padding(.bottom, 24) } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String.localized("Stop")) {
                        services.signing.cancel(model.activeRequestIDForCancellation ?? "")
                        model.cancel()
                    }
                    .disabled(!model.isBusy)
                }
            }
            .fileImporter(isPresented: $isImportingPackage, allowedContentTypes: [UTType(filenameExtension: "deb")].compactMap { $0 }) { result in
                switch result {
                case .success(let url):
                    Task {
                        _ = await services.tweaks.importTweak(name: url.deletingPathExtension().lastPathComponent, fromFiles: [url])
                        selectedTweakIDs = Set(services.tweaks.tweaks.map(\.id))
                        await model.inspect(tweaks: services.tweaks.tweaks, using: services.tweaks)
                    }
                case .failure(let error): model.message = error.localizedDescription
                }
            }
            .alert(String.localized("Modification"), isPresented: Binding(
                get: { model.message != nil },
                set: { if !$0 { model.message = nil } }
            )) {
                Button(String.localized("OK"), role: .cancel) { }
            } message: {
                Text(model.message ?? "")
            }
            .task { model.reloadProfiles() }
        }
    }

    private var _apps: [LibraryAppRecord] { services.workspace.snapshot.apps }
    private var _selectedApp: LibraryAppRecord? {
        guard let selectedAppID else { return _apps.first }
        return _apps.first { $0.id == selectedAppID } ?? _apps.first
    }
    private var _selectedTweaks: [ManagedTweak] {
        services.tweaks.tweaks.filter { selectedTweakIDs.contains($0.id) }
    }

    // MARK: Packages

    private var _packagesSection: some View {
        Section {
            Button {
                isImportingPackage = true
            } label: {
                Label(String.localized("Import .deb Package"), systemImage: "shippingbox.badge.plus")
            }
            Button {
                Task { await model.inspect(tweaks: services.tweaks.tweaks, using: services.tweaks) }
            } label: {
                Label(String.localized("Inspect Selected Tweaks"), systemImage: "doc.text.magnifyingglass")
            }
            ForEach(model.inspections, id: \.fileName) { inspection in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedPackage == inspection.fileName },
                        set: { expandedPackage = $0 ? inspection.fileName : nil }
                    )
                ) {
                    _packageDetails(inspection)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(inspection.label).font(.headline)
                            Text(inspection.version.map { "v\($0)" } ?? inspection.fileName)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(inspection.outcome.displayName)
                            .font(.caption)
                            .foregroundStyle(inspection.outcome.permitsInjection ? .green : .orange)
                    }
                }
            }
            ForEach(services.tweaks.tweaks) { tweak in
                Toggle(tweak.name, isOn: Binding(
                    get: { selectedTweakIDs.contains(tweak.id) },
                    set: { enabled in
                        if enabled { selectedTweakIDs.insert(tweak.id) }
                        else { selectedTweakIDs.remove(tweak.id) }
                    }
                ))
                .font(.subheadline)
            }
        } header: {
            Text(String.localized("Packages & Tweak Library"))
        } footer: {
            Text(String.localized("Packages are inspected without executing scripts or binaries. Unsupported archives are refused."))
                .font(.footnote)
        }
    }

    @ViewBuilder
    private func _packageDetails(_ inspection: TweakPackageInspection) -> some View {
        LabeledContent(String.localized("Identifier"), value: inspection.packageID ?? "—")
        LabeledContent(String.localized("Architecture"), value: inspection.architecture ?? "—")
        LabeledContent(String.localized("Maintainer"), value: inspection.maintainer ?? "—")
        LabeledContent(String.localized("Layout"), value: inspection.layout.title)
        LabeledContent(String.localized("Depends"), value: inspection.depends.map(\.name).joined(separator: ", "))
        LabeledContent(String.localized("Conflicts"), value: inspection.conflicts.map(\.name).joined(separator: ", "))
        LabeledContent(String.localized("Dylibs"), value: "\(inspection.dylibs.count)")
        LabeledContent(String.localized("Frameworks"), value: "\(inspection.frameworks.count)")
        LabeledContent(String.localized("Scripts ignored"), value: inspection.ignoredScripts.joined(separator: ", "))
        ForEach(inspection.findings) { finding in
            Text(finding.detail).font(.caption2).foregroundStyle(.secondary)
        }
        if !inspection.installPaths.isEmpty {
            DisclosureGroup(String.localized("Install Paths")) {
                ForEach(inspection.installPaths.prefix(24), id: \.self) { path in
                    Text(path).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    // MARK: Application and plan

    private var _applicationSection: some View {
        Section {
            Picker(String.localized("Application"), selection: Binding(
                get: { selectedAppID ?? _apps.first?.id ?? "" },
                set: { selectedAppID = $0 }
            )) {
                ForEach(_apps) { app in
                    Text(app.name ?? app.identifier ?? app.id).tag(app.id)
                }
            }
            Button {
                guard let app = _selectedApp else { return }
                model.buildPlan(
                    app: app,
                    tweaks: _selectedTweaks,
                    tweakModel: services.tweaks,
                    signing: services.signing
                )
            } label: {
                Label(String.localized("Build Modification Plan"), systemImage: "list.bullet.clipboard")
            }
            .disabled(_selectedApp == nil || _selectedTweaks.isEmpty)
        } header: {
            Text(String.localized("Authorized Application"))
        } footer: {
            Text(String.localized("Only applications you own or are authorized to modify may be selected. The original import is never overwritten."))
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var _planSection: some View {
        if let plan = model.plan {
            Section {
                LabeledContent(String.localized("Outcome"), value: plan.outcome.displayName)
                LabeledContent(String.localized("Package count"), value: "\(plan.selectedPackageIDs.count)")
                LabeledContent(String.localized("Signing verification"), value: plan.requiresSignatureVerification ? String.localized("Required") : String.localized("Not required"))
                ForEach(plan.steps) { step in
                    HStack {
                        Image(systemName: _icon(for: step.kind))
                        Text(step.summary).font(.caption)
                    }
                }
                ForEach(plan.findings, id: \.id) { finding in
                    Text(finding.detail).font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    guard let app = _selectedApp else { return }
                    model.apply(
                        plan: plan,
                        app: app,
                        tweaks: _selectedTweaks,
                        tweakModel: services.tweaks,
                        signing: services.signing
                    )
                } label: {
                    Label(String.localized("Apply and Sign"), systemImage: "signature")
                }
                .disabled(!plan.canApply || model.isBusy)
            } header: {
                Text(String.localized("Modification Preview"))
            }
        }
    }

    private func _icon(for kind: InjectionStep.Kind) -> String {
        switch kind {
        case .placePayload: return "shippingbox"
        case .addLoadCommand: return "doc.badge.gearshape"
        case .redirectHookRuntime: return "arrow.triangle.turn.up.right.diamond"
        case .reSignNestedCode: return "signature"
        case .verifySignature: return "checkmark.seal"
        }
    }

    @ViewBuilder
    private var _resultsSection: some View {
        if let report = model.operationReport {
            Section {
                LabeledContent(String.localized("Status"), value: report.status.rawValue)
                LabeledContent(String.localized("Plan"), value: report.planID)
                LabeledContent(String.localized("Completed steps"), value: "\(report.completedSteps.count)")
                if let failed = report.failedStep {
                    Text(failed).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text(String.localized("Operation Report"))
            }
        }
        if let verification = model.verificationReport {
            Section {
                LabeledContent(String.localized("Verification"), value: verification.verdict)
                Text(verification.summary).font(.caption)
                LabeledContent(String.localized("Failures"), value: "\(verification.failureCount)")
                LabeledContent(String.localized("Warnings"), value: "\(verification.warningCount)")
            } header: {
                Text(String.localized("Signature Verification"))
            }
        }
    }

    @ViewBuilder
    private var _profilesSection: some View {
        Section {
            TextField(String.localized("Profile Name"), text: $profileName)
            Button {
                guard let app = _selectedApp, let plan = model.plan else { return }
                model.saveProfile(name: profileName, app: app, tweaks: _selectedTweaks, plan: plan)
                profileName = ""
            } label: {
                Label(String.localized("Save Current Configuration"), systemImage: "square.and.arrow.down")
            }
            .disabled(model.plan == nil || profileName.isEmpty)
            ForEach(model.profiles) { profile in
                VStack(alignment: .leading) {
                    HStack {
                        Text(profile.name)
                        Spacer()
                        Text("\(profile.entries.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(profile.appBundleIdentifier).font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button(String.localized("Duplicate")) { model.duplicateProfile(profile) }
                        Button(String.localized("Delete"), role: .destructive) { model.deleteProfile(profile) }
                    }
                    .font(.caption)
                }
            }
        } header: {
            Text(String.localized("Saved Modification Profiles"))
        } footer: {
            Text(String.localized("Profiles reference imported tweaks and validated versions. References to removed packages are pruned automatically."))
                .font(.footnote)
        }
    }
}
