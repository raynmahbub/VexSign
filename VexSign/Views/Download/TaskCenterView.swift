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
	@ObservedObject private var center = UnifiedTaskCenter.shared
	@State private var filter: TaskFilter = .active
    @State private var confirmClear = false
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

	var body: some View {
		NBNavigationView(.localized("Task Center"), displayMode: .inline) {
			List {
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
	let task: UnifiedTask
    @State private var expanded = false

	var body: some View {
        VStack(alignment: .leading, spacing: 8) {
		HStack(spacing: 12) {
			ZStack {
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.fill(phaseColor.opacity(0.14))
					.frame(width: 40, height: 40)
				Image(systemName: task.kind.icon)
					.font(.system(size: 16, weight: .semibold))
					.foregroundStyle(phaseColor)
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
					_ = center.retry(task)
				} label: {
					Image(systemName: "arrow.clockwise")
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
                Button {
                    UIPasteboard.general.string = TaskReceipt.report(for: task)
                    Toast.success(.localized("Copied"))
                } label: {
                    Label(.localized("Copy Redacted Report"), systemImage: "doc.on.doc")
                }
                if task.phase == .failed {
                    recoveryActions
                }
                if (task.phase == .failed || task.phase == .cancelled) && !center.canRetry(task) {
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
	}

    @ViewBuilder
    private var recoveryActions: some View {
        let guide = TaskRecoveryGuide.resolve(kind: task.kind, failureStage: task.failureStage)
        Text(.localized("Suggested next steps")).font(.caption.bold())
        Text(guide.detail).font(.caption).foregroundStyle(.secondary)
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
		case .downloading, .extracting, .signing, .installing: return Color.userTint
		case .paused: return .orange
		case .completed: return .green
		case .failed: return .orange
		case .cancelled: return .secondary
		}
	}

	private var phaseBadge: some View {
		HStack(spacing: 3) {
			if task.failureStage != nil, task.phase == .failed {
				Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
					.font(.system(size: 8, weight: .bold))
			}
			Text(task.phase.title)
				.font(.system(size: 10, weight: .semibold))
		}
		.padding(.horizontal, 7)
		.padding(.vertical, 2)
		.background(phaseColor.opacity(0.14), in: Capsule())
		.foregroundStyle(phaseColor)
	}
}
