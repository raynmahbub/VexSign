//
//  PerAppUpdateRules.swift
//  VexSign
//
//  Per-app update rules: ignore a version, ignore a source, pin the signing
//  certificate, disable automatic updates, prefer a specific repository and
//  preserve custom signing options across updates. Keyed by bundle
//  identifier, persisted as JSON in UserDefaults.
//
//  `AppUpdateChecker` consults these rules while computing pending updates;
//  the signing flow honors `pinnedCertificateUUID` and
//  `preserveSigningOptions` when an update is signed.
//

import Foundation
import Combine

struct PerAppUpdateRule: Codable, Equatable, Sendable {
	/// No update check, badge or Update All entry for this app.
	var disableUpdates = false
	/// Skip exactly this version (e.g. a broken release) but keep checking.
	var ignoredVersion: String?
	/// Never update from this source identifier.
	var ignoredSourceID: String?
	/// Prefer this repository when several publish the app.
	var preferredSourceID: String?
	/// Sign updates with this certificate (by uuid).
	var pinnedCertificateUUID: String?
	/// Keep the app's custom signing options (name, bundle id, tweaks…) on update.
	var preserveSigningOptions = true

	var isEmpty: Bool {
		self == PerAppUpdateRule()
	}
}

final class PerAppUpdateRulesStore: ObservableObject {
	static let shared = PerAppUpdateRulesStore()

	static let defaultsKey = "VexSign.perAppUpdateRules"

	/// bundle identifier → rule. Mutated on the main thread (drives UI).
	@Published private(set) var rules: [String: PerAppUpdateRule]

	private init() {
		rules = Self.persisted
	}

	/// Snapshot from UserDefaults — safe off the main thread.
	static var persisted: [String: PerAppUpdateRule] {
		guard let data = UserDefaults.standard.data(forKey: defaultsKey),
		      let decoded = try? JSONDecoder().decode([String: PerAppUpdateRule].self, from: data) else {
			return [:]
		}
		return decoded
	}

	func rule(forBundleID bundleID: String?) -> PerAppUpdateRule {
		guard let bundleID, !bundleID.isEmpty else { return PerAppUpdateRule() }
		return rules[bundleID] ?? PerAppUpdateRule()
	}

	func setRule(_ rule: PerAppUpdateRule, forBundleID bundleID: String?) {
		guard let bundleID, !bundleID.isEmpty else { return }
		if rule.isEmpty {
			rules.removeValue(forKey: bundleID)
		} else {
			rules[bundleID] = rule
		}
		_persist()
	}

	func updateRule(forBundleID bundleID: String?, mutate: (inout PerAppUpdateRule) -> Void) {
		guard let bundleID, !bundleID.isEmpty else { return }
		var rule = rules[bundleID] ?? PerAppUpdateRule()
		mutate(&rule)
		setRule(rule, forBundleID: bundleID)
	}

	func removeRule(forBundleID bundleID: String?) {
		guard let bundleID else { return }
		rules.removeValue(forKey: bundleID)
		_persist()
	}

	// MARK: - Update filtering (the consumer side of the settings)

	/// Decides whether a source update should be surfaced for an installed app.
	/// Mirrors the logic `AppUpdateChecker` applies while precomputing.
	@discardableResult
	static func shouldSurfaceUpdate(
		bundleID: String?,
		installedVersion: String?,
		sourceVersion: String?,
		sourceID: String?
	) -> Bool {
		guard let bundleID, !bundleID.isEmpty else { return true }
		let rule = persisted[bundleID] ?? PerAppUpdateRule()

		if rule.disableUpdates { return false }
		if let ignored = rule.ignoredVersion, !ignored.isEmpty,
		   let sourceVersion, sourceVersion.compare(ignored, options: .caseInsensitive) == .orderedSame {
			return false
		}
		if let ignoredSource = rule.ignoredSourceID, !ignoredSource.isEmpty,
		   let sourceID, sourceID == ignoredSource {
			return false
		}
		return true
	}

	/// Among several sources publishing the same bundle id, the one matching
	/// the preferred-source rule wins; otherwise the caller's own priority
	/// order applies.
	static func preferredSourceID(forBundleID bundleID: String?) -> String? {
		guard let bundleID, !bundleID.isEmpty else { return nil }
		let rule = persisted[bundleID] ?? PerAppUpdateRule()
		return rule.preferredSourceID
	}

	private func _persist() {
		if let data = try? JSONEncoder().encode(rules) {
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
		NotificationCenter.default.post(name: .perAppUpdateRulesChanged, object: nil)
	}
}

extension Notification.Name {
	static let perAppUpdateRulesChanged = Notification.Name("VexSign.perAppUpdateRulesChanged")
}
