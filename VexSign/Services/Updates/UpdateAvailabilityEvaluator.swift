//
//  UpdateAvailabilityEvaluator.swift
//  VexSign
//
//  One answer to "is this catalogue entry an update for this installed app?".
//  Identity is the bundle identifier, never a display name. Version and build
//  comparisons go through `VersionOrder`, the app's single comparator, so the
//  notification, the Updates list and the download button cannot disagree.
//
//  A decision never installs anything. It only says what a notification or
//  the authenticated Updates screen may report.
//

import Foundation
import CryptoKit
import NimbleExtensions

struct UpdateCandidate: Equatable, Sendable {
    let bundleID: String
    let name: String
    let version: String
    let build: String?
    /// Non-nil only when the source actually offered a download.
    let downloadURL: URL?
}

struct InstalledAppVersion: Equatable, Sendable {
    let bundleID: String
    let version: String?
    let build: String?
}

enum UpdateAvailability: Equatable, Sendable {
    case available(reason: String)
    case upToDate
    case downgrade
    case incompatible
    case unknownIdentity
    case unavailableFromSource
    case invalidVersion
}

enum UpdateAvailabilityEvaluator {
    static func normalizedBundleID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `isCompatible` comes from the caller's deployment/device check; a build
    /// that cannot run is never announced as an update.
    static func evaluate(
        candidate: UpdateCandidate,
        installed: InstalledAppVersion,
        isCompatible: (UpdateCandidate) -> Bool = { _ in true }
    ) -> UpdateAvailability {
        let candidateID = normalizedBundleID(candidate.bundleID)
        let installedID = normalizedBundleID(installed.bundleID)
        guard !candidateID.isEmpty, candidateID == installedID else { return .unknownIdentity }
        guard candidate.downloadURL != nil else { return .unavailableFromSource }
        guard isCompatible(candidate) else { return .incompatible }

        let candidateVersion = candidate.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let installedVersion = installed.version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidateVersion.isEmpty, !installedVersion.isEmpty else { return .invalidVersion }
        guard VersionOrder.precedence(candidateVersion, installedVersion) != nil else { return .invalidVersion }

        if VersionOrder.isNewer(candidateVersion, than: installedVersion) {
            return .available(reason: "version")
        }
        if VersionOrder.isSame(candidateVersion, installedVersion),
           let candidateBuild = candidate.build?.trimmingCharacters(in: .whitespacesAndNewlines),
           let installedBuild = installed.build?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidateBuild.isEmpty, !installedBuild.isEmpty,
           VersionOrder.precedence(candidateBuild, installedBuild) != nil,
           VersionOrder.isNewer(candidateBuild, than: installedBuild) {
            return .available(reason: "build")
        }
        if VersionOrder.isNewer(installedVersion, than: candidateVersion) { return .downgrade }
        return .upToDate
    }

    /// Stable across re-checks and launches. The digest keeps the bundle
    /// identifier out of persisted keys and notification identifiers.
    static func stableKey(candidate: UpdateCandidate) -> String {
        let value = "\(normalizedBundleID(candidate.bundleID))|\(candidate.version)|\(candidate.build ?? "")"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func message(for availability: UpdateAvailability, candidate: UpdateCandidate) -> String? {
        switch availability {
        case .available(let reason):
            let suffix = reason == "build" ? " (\(String.localized("new build")))" : ""
            return String.localized("“%@” %@%@ is available.", arguments: candidate.name, candidate.version, suffix)
        case .unknownIdentity, .unavailableFromSource, .incompatible, .downgrade, .invalidVersion, .upToDate:
            return nil
        }
    }
}

/// Dismissals are remembered per stable update key. An install of a new
/// version clears every dismissal for that bundle ID so a later release is
/// never suppressed by an old "skip".
@MainActor
final class UpdateDismissalStore: ObservableObject {
    static let storageKey = "VexSign.updates.dismissed.v1"
    static let limit = 50

    @Published private(set) var keys: [String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.keys = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    func isDismissed(_ key: String) -> Bool { keys.contains(key) }

    func canNotify(for candidate: UpdateCandidate) -> Bool {
        !isDismissed(UpdateAvailabilityEvaluator.stableKey(candidate: candidate))
    }

    func dismiss(_ key: String) {
        guard !keys.contains(key) else { return }
        keys = Array((keys + [key]).suffix(Self.limit))
        defaults.set(keys, forKey: Self.storageKey)
    }

    /// Called only after an installation service confirms a new version is running.
    func clearDismissals(bundleID: String) {
        // Digests cannot be prefix-matched; the caller supplies the key through
        // `clear(key:)` for the specific release, while this removes stored
        // bundle-scoped records kept by `rememberInstalled`.
        let scoped = defaults.stringArray(forKey: installedScopeKey(bundleID)) ?? []
        keys.removeAll { scoped.contains($0) }
        defaults.set(keys, forKey: Self.storageKey)
        defaults.removeObject(forKey: installedScopeKey(bundleID))
    }

    func rememberInstalled(key: String, bundleID: String) {
        let scope = installedScopeKey(bundleID)
        let existing = defaults.stringArray(forKey: scope) ?? []
        if !existing.contains(key) { defaults.set(existing + [key], forKey: scope) }
    }

    func clear(key: String) {
        keys.removeAll { $0 == key }
        defaults.set(keys, forKey: Self.storageKey)
    }

    private func installedScopeKey(_ bundleID: String) -> String {
        Self.storageKey + ".installed." + UpdateAvailabilityEvaluator.normalizedBundleID(bundleID)
    }
}
