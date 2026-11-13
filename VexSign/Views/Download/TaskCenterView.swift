//
//  TaskCenterView.swift
//  VexSign
//
//  The unified task center: downloads, imports, signing jobs and
//  installations in one list, with live progress, the exact failure stage,
//  retry/cancel actions and a persistent history.
//
//  Surfaced from the Downloads tab toolbar and Home.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct TaskCenterView: View {
    /// False when embedded in a workspace or pushed from another navigation stack.
    var ownsNavigationStack: Bool = false
	@ObservedObject private var center = UnifiedTaskCenter.shared
    @ObservedObject private var recovery = DownloadManager.shared
	@State private var filter: TaskFilter = .active
    @State private var confirmClear = false
    /// The record a swipe just removed, kept so the removal can be undone for a few seconds.
    @State private var lastRemoved: UnifiedTask?
    @State private var query = ""
    @State private var sort: TaskHistorySort = .latest

	enum TaskFilter: String, CaseIterable, Identifiable {
		case active = "Active"
		case failed = "Failed"
		case history = "History"
		case all = "All"
		var id: String { rawValue }
        var title: String {
            switch self {
            case .active: return .localized("Active")
            case .failed: return .localized("Failed")
            case .history: return .localized("History")
            case .all: return .localized("All")
            }
        }
	}

	private var scopedTasks: [UnifiedTask] {
		switch filter {
		case .active: return center.tasks.filter { $0.phase.isInProgress }
		case .failed: return (center.tasks + center.history).filter { $0.phase == .failed }
		case .history: return center.history
		case .all: return center.tasks + center.history
		}
	}

    private var filteredTasks: [UnifiedTask] {
        TaskHistoryQuery.results(scopedTasks, query: query, sort: sort)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var historyWarning: String? {
        switch center.historyPersistenceIssue {
        case .inaccessible, .notLoaded:
            return .localized("Task history cannot be read. Existing data is retained; new history will be saved after access is restored.")
        case .corruptPreserved:
            return .localized("Unreadable task history was preserved in a recovery file. New task history can still be saved.")
        case .recordsDropped:
            return .localized("Some task history entries could not be read. The rest was restored, and the original file was kept as a recovery copy.")
        case .preservationFailed:
            return .localized("Task history recovery could not be saved. The original history was kept; history writes are paused.")
        case .writeFailed:
            return .localized("Recent task history could not be saved. Previously saved history has not been replaced.")
        case nil:
            return nil
        }
    }

	var body: some View {
		NBNavigationView(.localized("Task Center"), displayMode: .inline, ownsNavigationStack: ownsNavigationStack) {
			List {
                if let removed = lastRemoved {
                    Section {
                        HStack {
                            Text(String.localized("Removed %@", arguments: removed.title))
                                .font(.subheadline).lineLimit(1)
                            Spacer()
                            Button(.localized("Undo")) {
                                center.restoreToHistory(removed)
                                lastRemoved = nil
                            }
                            .buttonStyle(.borderless)
                        }
                        // Keyed by the record, so removing another one restarts the countdown.
                        .task(id: removed.id) {
                            do { try await Task.sleep(for: .seconds(6)) } catch { return }
                            if lastRemoved?.id == removed.id { lastRemoved = nil }
                        }
                    }
                }
                if let warning = recovery.recoveryWarning {
                    Section { Text(warning).font(.caption).foregroundStyle(.orange) }
                }
                if !recovery.interruptedDownloads.isEmpty {
                    Section {
                        ForEach(recovery.interruptedDownloads) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: record.name)
                                Text(record.updatedAt, style: .date).font(.caption)
                                if let journal = recovery.recoveryJournal,
                                   let file = journal.stagedFile(for: record, in: FileManager.default.downloadStaging) {
                                    if record.canReverify {
                                        Button(.localized("Recheck and import retained IPA")) { recovery.reverifyRecovery(record) }
                                    }
                                    ShareLink(item: file) { Label(.localized("Review retained IPA"), systemImage: "square.and.arrow.up") }
                                }
                                if record.libraryUUID != nil {
                                    Text(.localized("An import commit was recorded or attempted. Check Library before downloading again; this input is not replayed automatically."))
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                if record.sourceURL != nil {
                                    Button(record.stage == .downloading ? String.localized("Resume or download again") : String.localized("Download again")) { recovery.retryRecoveryDownload(record) }
                                }
                                Button(.localized("Forget recovery record"), role: .destructive) { recovery.forgetRecovery(record) }
                            }
                        }
                    } header: { Text(.localized("Interrupted downloads")) } footer: {
                        Text(.localized("No import is replayed automatically. An interrupted import may already have saved a library copy: check Library before retrying. Resume or download again uses your existing auto-sign settings. A saved system resume blob is used only if its original URL matches; otherwise a fresh download is required. Forget removes only the checkpoint, not the retained IPA. Token-bearing URLs are not saved; reopen the original source when no retry is offered."))
                    }
                }
                if let historyWarning {
                    Section {
                        Label(historyWarning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

				Section {
					Picker(.localized("Show"), selection: $filter) {
						ForEach(TaskFilter.allCases) { f in
							Text(f.title).tag(f)
						}
					}
					.pickerStyle(.segmented)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
				}

                Section {
                    Picker(.localized("Sort tasks"), selection: $sort) {
                        ForEach(TaskHistorySort.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    LabeledContent(.localized("In progress"), value: center.tasks.filter { $0.phase.isInProgress }.count.description)
                    LabeledContent(.localized("Failed"), value: (center.tasks + center.history).filter { $0.phase == .failed }.count.description)
                }

				if filteredTasks.isEmpty {
					NBContentUnavailable(
                        isSearching ? .localized("No matching tasks") : .localized("No Tasks"),
                        systemImage: isSearching ? "magnifyingglass" : "checkmark.circle",
                        description: isSearching
                            ? .localized("Search applies to the selected filter. Try fewer words or switch to All.")
                            : .localized("Downloads, imports, signing jobs and installations appear here with their exact stage.")
					)
					.listRowBackground(Color.clear)
				} else {
					ForEach(filteredTasks, id: \.id) { task in
						TaskRow(task: task)
							.swipeActions(edge: .trailing, allowsFullSwipe: false) {
								// Only a stopped record can be removed. A running task has no
								// action here: removing its row would not stop the work, and
								// a button that only hid it would say otherwise.
								if center.history.contains(where: { $0.id == task.id }) {
									Button(role: .destructive) {
										if center.removeFromHistory(id: task.id) { lastRemoved = task }
									} label: {
										Label(.localized("Remove"), systemImage: "trash")
									}
								}
							}
					}
				}

				if !center.history.isEmpty {
					Section {
						Button(role: .destructive) {
							confirmClear = true
						} label: {
							Label(.localized("Clear Task History"), systemImage: "trash")
						}
					} footer: {
						Text(.localized("History keeps the last 200 finished tasks (names and outcomes only)."))
					}
				}
			}
            .searchable(text: $query, prompt: Text(.localized("Search tasks, stages or errors")))
            .scrollDismissesKeyboard(.interactively)
		}
        .confirmationDialog(.localized("Clear Task History?"), isPresented: $confirmClear) {
            Button(.localized("Clear Task History"), role: .destructive) { center.clearHistory() }
            Button(.localized("Cancel"), role: .cancel) {}
        }
	}
}

// MARK: - Row

private struct TaskRow: View {
	@ObservedObject private var center = UnifiedTaskCenter.shared
    @ObservedObject private var recovery = DownloadManager.shared
	let task: UnifiedTask
    @State private var expanded = false
    @State private var confirmRetry = false

    /// Starting again is the user's decision, and when the last attempt reached iOS without
    /// an answer they are told the app may already be there before it is taken.
    private func requestRetry() {
        if task.kind == .install, TaskReceipt.evidence(for: task).isOutcomeUnknown {
            confirmRetry = true
        } else {
            _ = center.retry(task)
        }
    }

	var body: some View {
        VStack(alignment: .leading, spacing: 8) {
		HStack(spacing: 12) {
			ZStack {
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.fill(phaseColor.opacity(0.14))
					.frame(width: 40, height: 40)
                if let icon = center.historyIcon(for: task) {
                    Image(uiImage: icon).resizable().scaledToFit()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: task.kind.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(phaseColor)
                }
			}

			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 6) {
					Text(LogRedaction.redact(task.title))
						.font(.subheadline.weight(.semibold))
						.lineLimit(2)
					phaseBadge
				}

				if let subtitle = task.subtitle, !subtitle.isEmpty {
					Text(subtitle)
						.font(.caption2)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}

				if let error = task.errorText, !error.isEmpty {
					// Always icon + text, never color alone.
					Label(LogRedaction.redact(error), systemImage: "exclamationmark.triangle.fill")
						.font(.caption2)
						.foregroundStyle(.orange)
						.lineLimit(2)
				}

				if task.phase.isInProgress && task.progress >= 0 {
					ProgressView(value: min(max(task.progress, 0), 1))
						.tint(phaseColor)
				}
			}

			Spacer(minLength: 8)

			if center.canRetry(task) {
				Button {
					requestRetry()
				} label: {
					Label(task.kind == .install ? String.localized("Retry Install") : String.localized("Retry"), systemImage: "arrow.clockwise")
				}
				.buttonStyle(.borderless)
				.accessibilityLabel(Text(.localized("Retry")))
			}
		}
        DisclosureGroup(.localized("Task Details"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(.localized("Started")) { Text(task.createdAt, style: .time) }
                LabeledContent(.localized("Last updated")) { Text(task.updatedAt, style: .relative) }
                if let stage = task.failureStage {
                    LabeledContent(.localized("Failure stage"), value: stage.title)
                }
                if let error = task.errorText, !error.isEmpty {
                    Text(LogRedaction.redact(error)).font(.caption.monospaced()).textSelection(.enabled)
                }
                Text(TaskReceipt.outcome(for: task)).foregroundStyle(.secondary)
                DisclosureGroup(.localized("View Report")) {
                    Text(TaskReceipt.report(for: task))
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                Button {
                    UIPasteboard.general.string = TaskReceipt.report(for: task)
                    Toast.success(.localized("Copied"))
                } label: {
                    Label(.localized("Copy Redacted Report"), systemImage: "doc.on.doc")
                }
                if task.phase == .failed || task.phase == .interrupted || task.phase == .unconfirmed {
                    recoveryActions
                }
                if (task.phase == .failed || task.phase == .cancelled || task.phase == .interrupted || task.phase == .unconfirmed) && !center.canRetry(task) {
                    Text(.localized("Retry is unavailable for this saved task. Restart the action from its original app or download screen."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if task.phase.isInProgress && task.progress < 0 {
                    ProgressView().accessibilityLabel(Text(.localized("Working")))
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
        }
        .padding(.vertical, 2)
        .confirmationDialog(.localized("Install again?"), isPresented: $confirmRetry, titleVisibility: .visible) {
            Button(.localized("Install Again")) { _ = center.retry(task) }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("The last attempt was handed to iOS and its result is unknown, so the app may already be installed. Check the Home Screen first."))
        }
	}

    @ViewBuilder
    private var recoveryActions: some View {
        let guide = TaskRecoveryGuide.resolve(kind: task.kind, failureStage: task.failureStage)
        Text(.localized("Suggested next steps")).font(.caption.bold())
        if task.phase == .unconfirmed {
            // Nothing is known to have failed, so do not send the user back through the
            // installation-method checklist first.
            Text(.localized("Check the Home Screen and the app details in Library. iOS did not report the result, so the app may already be installed. Install again only if it is missing."))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(guide.detail).font(.caption).foregroundStyle(.secondary)
        }
        switch guide {
        case .download:
            NavigationLink(destination: DownloadsSettingsView()) {
                Label(.localized("Download Manager"), systemImage: "arrow.down.circle")
            }
        case .archive:
            NavigationLink(destination: StorageView()) {
                Label(.localized("Storage Breakdown"), systemImage: "internaldrive")
            }
        case .signing:
            NavigationLink(destination: CertificatesView()) {
                Label(.localized("Certificates Manager"), systemImage: "checkmark.seal")
            }
            NavigationLink(destination: ConfigurationView()) {
                Label(.localized("Signing Options"), systemImage: "signature")
            }
        case .installation:
            NavigationLink(destination: InstallationView()) {
                Label(.localized("Installation Engine"), systemImage: "arrow.down.app")
            }
        case .general:
            EmptyView()
        }
        NavigationLink(destination: LogsHistoryView()) {
            Label(.localized("Activity Logs"), systemImage: "text.alignleft")
        }
    }

	private var phaseColor: Color {
		switch task.phase {
		case .queued: return .secondary
		case .downloading, .extracting, .signing, .installing, .importing, .readyToSign, .signed, .preparingInstallation, .waitingForIOS, .verifying: return Color.userTint
		case .paused: return .orange
		case .completed: return .green
		case .failed: return .orange
		case .unconfirmed: return .orange
		case .cancelled, .interrupted: return .secondary
		}
	}

	private var phaseBadge: some View {
		HStack(spacing: 3) {
			if task.failureStage != nil, task.phase == .failed {
				Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
					.font(.system(size: 8, weight: .bold))
			}
			Text(task.displayPhaseTitle)
				.font(.system(size: 10, weight: .semibold))
		}
		.padding(.horizontal, 7)
		.padding(.vertical, 2)
		.background(phaseColor.opacity(0.14), in: Capsule())
		.foregroundStyle(phaseColor)
	}
}
