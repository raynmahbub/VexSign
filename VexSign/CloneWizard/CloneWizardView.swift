import SwiftUI
import NimbleExtensions

struct ClonePlan: Identifiable, Sendable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let displayName: String
    let ordinal: Int
    static func make(bundleID: String, name: String, count: Int, existing: Set<String>) throws -> [ClonePlan] {
        guard (1...20).contains(count), bundleID.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            throw RepositoryError.invalid(.localized("Enter a valid bundle ID and between 1 and 20 clones."))
        }
        var used = Set(existing.map { $0.lowercased() }); var result: [ClonePlan] = []; var number = 1
        while result.count < count {
            let candidate = "\(bundleID).clone\(number)"
            if used.insert(candidate.lowercased()).inserted { result.append(.init(bundleIdentifier: candidate, displayName: "\(name) \(number)", ordinal: number)) }
            number += 1
        }
        return result
    }
}

struct CloneWizardView: View {
    @State private var selected: AppInfoPresentable?
    @State private var picking = false
    @State private var count = 1
    @State private var busy = false
    @State private var progress = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section(.localized("Original App")) {
                Button(selected?.name ?? .localized("Choose from Library")) { picking = true }
                Stepper(value: $count, in: 1...20) { Text(String.localized("%lld clones", arguments: count)) }
                Text(.localized("Clones receive unique bundle IDs and display names. Re-sign every clone before installation; app groups, push, and associated domains may require a matching profile.")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(.localized("Create Clones")) { Task { await clone() } }.disabled(selected == nil || busy)
                if busy { ProgressView() }
                if !progress.isEmpty { Text(progress) }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }.navigationTitle(.localized("Clone Wizard"))
            .interactiveDismissDisabled(busy)
            .sheet(isPresented: $picking) { AppLibraryPicker { selected = $0 } }
            .disabled(busy)
    }
    @MainActor private func clone() async {
        guard let selected else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let existing = Set((Storage.shared.getImportedApps().compactMap(\.identifier)) + Storage.shared.getSignedApps().compactMap(\.identifier))
            let plans = try ClonePlan.make(bundleID: selected.identifier ?? "", name: selected.name ?? "App", count: count, existing: existing)
            for (index, plan) in plans.enumerated() {
                try Task.checkCancellation()
                progress = String.localized("Creating %lld of %lld…", arguments: index + 1, plans.count)
                _ = try await AppCloner.shared.clone(app: selected, customName: plan.displayName, customBundleId: plan.bundleIdentifier, asUnsigned: true, iconOrdinal: plan.ordinal)
            }
            progress = String.localized("Created %lld clones. Re-sign them from Library.", arguments: plans.count)
        } catch { self.error = error.localizedDescription }
    }
}
