//
//  AutomationView.swift
//  VexSign
//
//  Settings → Automation: the opt-in "Do-Not-Disturb of signing" — a scheduled background
//  pass that checks for updates, optionally signs + queues them, runs the cleanup sweep and
//  posts one summary notification. Installing still needs the user in the loop.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import NimbleExtensions

struct AutomationView: View {
	@AppStorage(BackgroundAutomationPreferences.enabledKey) private var _isEnabled: Bool = false
	@AppStorage(BackgroundAutomationPreferences.policyKey) private var _policyRaw: String = BackgroundAutomationPolicy.notifyOnly.rawValue

	@ObservedObject private var _history = AutomationHistoryStore.shared
    @State private var _confirmClear = false
    @State private var _confirmRun = false
    @ObservedObject private var _sources = SourcesViewModel.shared
    @ObservedObject private var _updates = AppUpdateChecker.shared
    @ObservedObject private var _updateRunner = UpdateAllManager.shared
    @AppStorage(GameMode.enabledKey) private var _gameMode = false

	@State private var _isRunning = false
	@State private var _lastResult: AutomationRunResult?

	// MARK: Body
	var body: some View {
		NBList(.localized("Automation")) {
			_enabledSection
			_policySection
            Section {
                NavigationLink(destination: AutomationPreviewView()) {
                    Label(.localized("Automation Preview"), systemImage: "list.bullet.clipboard")
                }
            }
			_runSection
            _historySection
        }
        .confirmationDialog(.localized("Run automation now?"), isPresented: $_confirmRun, titleVisibility: .visible) {
            Button(.localized("Run Now")) { _run() }
                .disabled(_runBlocker != nil)
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(_confirmationSummary)
        }
        .confirmationDialog(.localized("Clear automation history?"), isPresented: $_confirmClear) {
            Button(.localized("Clear History"), role: .destructive) { _history.clear() }
            Button(.localized("Cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var _historySection: some View {
        Section {
            if _history.entries.isEmpty {
                Text(.localized("No automation runs yet.")).foregroundStyle(.secondary)
            }
            ForEach(_history.entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(_outcome(entry.outcome)).font(.headline)
                        Spacer()
                        Text(entry.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.fromBackground ? .localized("Background run") : .localized("Manual run"))
                        .font(.caption).foregroundStyle(.secondary)
                    if entry.outcome == "completed" || entry.outcome == "partialFailure" {
                        Text(String.localized("%lld updates · %lld signed · %lld queued · %lld skipped", arguments: entry.updates, entry.signed, entry.queued, entry.skipped))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let failed = entry.failed, failed > 0 {
                        Text(String.localized("%lld failed", arguments: failed))
                            .font(.caption).foregroundStyle(.red)
                        Text(.localized("Review Activity Logs for signing failures. Certificate expiry, profile scope and download errors may need attention."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let duration = entry.duration {
                        Text(String.localized("Duration: %lld seconds", arguments: Int(duration.rounded())))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if !_history.entries.isEmpty {
                Button(.localized("Clear History"), role: .destructive) { _confirmClear = true }
            }
        } header: {
            Text(.localized("Automation History"))
        } footer: {
            Text(.localized("Keeps the latest 50 outcomes on this device. iOS decides when background tasks run; no exact refresh interval is guaranteed."))
        }
    }

    private func _outcome(_ value: String) -> String {
        switch value {
        case "completed": return .localized("Completed")
        case "partialFailure": return .localized("Completed with failures")
        case "noSources": return .localized("Skipped: no repositories configured")
        case "disabled": return .localized("Skipped: automation is disabled")
        case "busy": return .localized("Skipped: another run is active")
        case "gameMode": return .localized("Skipped: Game Mode is on")
        default: return .localized("Unknown outcome")
        }
    }

	@ViewBuilder
	private var _enabledSection: some View {
		NBSection(.localized("Scheduled Updates")) {
			Toggle(.localized("Automatic Update Checks"), isOn: $_isEnabled)
				.nbOnChange(of: _isEnabled) { enabled in
					if enabled {
						// Wrap the AppDelegate call on the main actor.
						DispatchQueue.main.async {
							if let delegate = UIApplication.shared.delegate as? AppDelegate {
								delegate.scheduleAutomationMaintenance()
							}
						}
					}
				}
		} footer: {
			Text(.localized("VexSign periodically checks your sources for updates while the app runs, so the Updates list is already ready when you open it."))
		}
	}

	@ViewBuilder
	private var _policySection: some View {
		NBSection(.localized("What To Do")) {
			Picker(.localized("When updates are found"), selection: $_policyRaw) {
				ForEach(BackgroundAutomationPolicy.allCases, id: \.rawValue) { policy in
					Text(policy.localizedDescription).tag(policy.rawValue)
				}
			}
			.pickerStyle(.inline)
			.labelsHidden()
		} footer: {
			let policy = BackgroundAutomationPolicy(rawValue: _policyRaw) ?? .notifyOnly
			Text(policy.localizedDetail)
		}
	}

	@ViewBuilder
	private var _runSection: some View {
		Section {
			Button {
				_confirmRun = true
			} label: {
				HStack {
					Label(.localized("Run Now"), systemImage: "arrow.triangle.2.circlepath")
					Spacer()
					if _isRunning {
						ProgressView()
					}
				}
			}
			.disabled(_isRunning || _runBlocker != nil)
            if let blocker = _runBlocker {
                Label(blocker, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
		} footer: {
			Text(.localized("Runs one automation pass immediately, exactly as the scheduled task would. Installations are never started without you."))
		}

		if let result = _lastResult {
			Section {
				LabeledContent(.localized("Sources checked"), value: result.refreshedSources.description)
				LabeledContent(.localized("Updates found"), value: result.foundUpdates.description)
				LabeledContent(.localized("Signed"), value: result.signed.description)
                LabeledContent(.localized("Failed"), value: result.failed.description)
				LabeledContent(.localized("Queued for install"), value: result.queueAdded.description)
				if let cleanup = result.cleanup, !cleanup.isIdle {
					LabeledContent(.localized("Cleaned up"), value: cleanup.freedBytes.formattedFileSize)
				}
			}
		}
	}

    private var _runBlocker: String? {
        if !_isEnabled { return .localized("Enable automatic update checks before running this policy.") }
        if _gameMode { return .localized("Turn off Game Mode to run automation.") }
        if _updateRunner.isRunning { return .localized("Wait for the current update queue to finish.") }
        if Storage.shared.getSources().isEmpty { return .localized("Add a repository before running automation.") }
        return nil
    }

    private var _confirmationSummary: String {
        let policy = BackgroundAutomationPolicy(rawValue: _policyRaw) ?? .notifyOnly
        _ = _updates.updateCount
        let candidates = AutomationCandidateSnapshot.tasks(from: Array(_sources.sources.values)).count
        return [
            policy.localizedDescription,
            String.localized("Current snapshot: %lld pending candidates.", arguments: candidates),
            policy.localizedDetail,
            .localized("This run refreshes repositories first, so the candidate count can change. It also runs configured cleanup. Installations still require your confirmation.")
        ].joined(separator: "\n\n")
    }

	private func _run() {
        guard !_isRunning, _runBlocker == nil else { return }
        _lastResult = nil
		_isRunning = true
		Task {
			let result = await BackgroundAutomation.run(fromBackground: false)
			_lastResult = result
			_isRunning = false

			if let result, result.foundUpdates == 0, result.failed == 0 {
				Toast.info(.localized("Everything is up to date."), systemImage: "checkmark.circle")
			}
		}
	}
}


private struct AutomationPreviewView: View {
    @ObservedObject private var sources = SourcesViewModel.shared
    @ObservedObject private var updates = AppUpdateChecker.shared
    @ObservedObject private var rules = PerAppUpdateRulesStore.shared
    @AppStorage(BackgroundAutomationPreferences.enabledKey) private var enabled = false
    @AppStorage(BackgroundAutomationPreferences.policyKey) private var policyRaw = BackgroundAutomationPolicy.notifyOnly.rawValue
    @AppStorage(GameMode.enabledKey) private var gameMode = false
    @State private var editing: RuleSelection?

    private struct RuleSelection: Identifiable {
        let id: String
        let name: String
        let version: String?
    }

    private var candidates: [UpdateTask] {
        // Observe the same checker that the queue builder consults.
        _ = updates.updateCount
        return AutomationCandidateSnapshot.tasks(from: Array(sources.sources.values))
    }

    var body: some View {
        NBList(.localized("Automation Preview")) {
            Section {
                LabeledContent(.localized("Background Automation"), value: enabled ? String.localized("Enabled") : String.localized("Disabled"))
                LabeledContent(.localized("Policy"), value: (BackgroundAutomationPolicy(rawValue: policyRaw) ?? .notifyOnly).localizedDescription)
                if gameMode {
                    Label(.localized("Paused by Game Mode"), systemImage: "pause.circle")
                }
                LabeledContent(.localized("Pending candidates"), value: candidates.count.description)
            } footer: {
                Text(.localized("Preview only: uses the current repository snapshot and update-check results. It does not refresh, download, sign or install anything. Certificate and profile compatibility are checked later."))
            }

            Section {
                if candidates.isEmpty {
                    Text(.localized("No pending candidates in the current snapshot."))
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { task in
                    Button {
                        if let bundleID = task.app.id, !bundleID.isEmpty {
                            editing = RuleSelection(id: bundleID, name: task.app.name ?? .localized("Application"), version: task.app.currentVersion)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.app.name ?? .localized("Application")).font(.headline)
                            Text(task.sourceName).font(.caption).foregroundStyle(.secondary)
                            if let version = task.app.currentVersion {
                                Text(version).font(.caption)
                            }
                        }
                    }
                    .disabled(task.app.id?.isEmpty != false)
                }
            } header: {
                Text(.localized("Pending candidates"))
            } footer: {
                Text(.localized("Tap an app to edit its update rules. Notify-only policy does not sign these candidates; sign-and-queue still requires a usable signing identity."))
            }

            Section {
                if rules.rules.isEmpty {
                    Text(.localized("No custom update rules."))
                        .foregroundStyle(.secondary)
                }
                ForEach(rules.rules.keys.sorted(), id: \.self) { bundleID in
                    if let rule = rules.rules[bundleID] {
                        Button {
                            editing = RuleSelection(id: bundleID, name: bundleID, version: nil)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(bundleID).font(.subheadline).lineLimit(2)
                                if rule.disableUpdates {
                                    Text(.localized("Updates disabled"))
                                }
                                if let version = rule.ignoredVersion {
                                    Text(String.localized("Ignoring version %@", arguments: version))
                                }
                                if rule.ignoredSourceID != nil {
                                    Text(.localized("A source is excluded"))
                                }
                                if rule.preferredSourceID != nil {
                                    Text(.localized("Preferred source configured"))
                                }
                                if rule.pinnedCertificateUUID != nil {
                                    Text(.localized("Certificate pinned"))
                                }
                                if rule.preserveSigningOptions {
                                    Text(.localized("Preserving signing options"))
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            } header: {
                Text(.localized("Per-app rules"))
            } footer: {
                Text(.localized("Rules can exclude apps or versions from update checks. This lists saved rules, not every possible exclusion reason. Preferred sources and pinned certificates do not guarantee compatibility."))
            }
        }
        .sheet(item: $editing) { selection in
            PerAppUpdateRulesView(appName: selection.name, bundleID: selection.id, currentVersion: selection.version)
        }
    }
}


@MainActor
private enum AutomationCandidateSnapshot {
    static func tasks(from repositories: [ASRepository]) -> [UpdateTask] {
        let entries = UpdateAllManager.makeTasks(
            from: repositories,
            signedApps: Storage.shared.getSignedApps(),
            importedApps: Storage.shared.getImportedApps()
        ).filter { $0.hasUpdate }
        return UpdateAllManager.shared.makeTasks(from: entries).sorted {
            ($0.app.name ?? "").localizedStandardCompare($1.app.name ?? "") == .orderedAscending
        }
    }
}
