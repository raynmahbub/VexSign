//
//  UpdatesView.swift
//  VexSign
//
//  The Updatable Apps list: every app with a newer version in your sources, one "Update All"
//  tap that downloads + re-signs + queues them in order, per-app update/skip, and ignore.
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import AltSourceKit
import CoreData

// MARK: - View
struct UpdatesView: View {
	@ObservedObject private var _updateChecker = AppUpdateChecker.shared
	@ObservedObject private var _runner = UpdateAllManager.shared

	@State private var _updates: [AppUpdateChecker.SourcedUpdate] = []
	@State private var _isLoading = true
	@State private var _showProgress = false
	@State private var _rulesApp: AppUpdateChecker.SourcedUpdate?

	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: []
	) private var _signedApps: FetchedResults<Signed>

	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: []
	) private var _importedApps: FetchedResults<Imported>

	var body: some View {
		NBList(.localized("Updates")) {
			if _isLoading {
				Section {
					HStack {
						Spacer()
						ProgressView()
						Spacer()
					}
					.listRowBackground(Color.clear)
				}
			} else if _updates.isEmpty {
				Section {
					HStack {
						Spacer()
						VStack(spacing: 8) {
							Image(systemName: "checkmark.circle.fill")
								.font(.system(size: 40))
								.foregroundStyle(Color.accentColor)
							Text(.localized("Everything is up to date."))
								.font(.subheadline)
								.foregroundStyle(.secondary)
						}
						.padding(.vertical, 32)
						Spacer()
					}
					.listRowBackground(Color.clear)
				}
			} else {
				Section {
					ForEach(_updates) { update in
						_row(update)
					}
				} footer: {
					Text(.localized("Update All downloads each app, signs it with its original settings and queues the installs in order. You still confirm each install."))
				}
			}
		}
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				if !_updates.isEmpty {
					Button(String.localized("Update All (%lld)", arguments: _updates.count)) {
						_showProgress = true
					}
					.font(.subheadline.bold())
				}
			}
		}
		.sheet(isPresented: $_showProgress) {
			UpdateAllProgressView(updates: _updates.map {
				(app: $0.app, sourceName: $0.sourceName, hasUpdate: true)
			})
		}
		.sheet(item: $_rulesApp) { update in
			PerAppUpdateRulesView(
				appName: update.displayName,
				bundleID: update.app.id ?? update.installedAppIdentifier ?? "",
				currentVersion: update.sourceVersion
			)
			.presentationDetents([.large])
			.onDisappear { Task { await _reload() } }
		}
		.refreshable { await _reload() }
		.task { await _reload() }
	}

	@ViewBuilder
	private func _row(_ update: AppUpdateChecker.SourcedUpdate) -> some View {
		Button {
			_updateOne(update)
		} label: {
			HStack(spacing: 12) {
				SourceAppIcon(app: update.app, size: 40)

				VStack(alignment: .leading, spacing: 2) {
					Text(update.displayName)
						.font(.headline)
						.lineLimit(1)

					Text(verbatim: _versionLine(update))
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}

				Spacer()

				Text(.localized("Update"))
					.font(.subheadline.bold())
					.foregroundStyle(.white)
					.padding(.horizontal, 14)
					.padding(.vertical, 5)
					.background(Color.accentColor, in: Capsule())
			}
		}
		.buttonStyle(.plain)
		.swipeActions(edge: .trailing) {
			Button(.localized("Update")) { _updateOne(update) }
				.tint(.accentColor)
		}
		.contextMenu {
			Button(.localized("Update Now"), systemImage: "arrow.down.circle") { _updateOne(update) }
			Button(.localized("Update Rules…"), systemImage: "slider.horizontal.3") {
				_rulesApp = update
			}
			if let bundleID = update.app.id {
				Button(.localized("Ignore Updates"), systemImage: "bell.slash") {
					SkippedUpdatesManager.shared.ignore(bundleID)
					Task { await _reload() }
				}
			}
		}
	}

	private func _versionLine(_ update: AppUpdateChecker.SourcedUpdate) -> String {
		let from = update.installedVersion ?? .localized("(?)")
		let to = update.sourceVersion ?? .localized("(?)")
		return "\(from) → \(to)"
	}

	private func _updateOne(_ update: AppUpdateChecker.SourcedUpdate) {
		guard let url = update.downloadURL else { return }
		Task {
			await UpdateAllManager.shared.run(tasks: [
				UpdateTask(
					id: update.id,
					app: update.app,
					sourceName: update.sourceName,
					url: url
				)
			])
		}
	}

	@MainActor
	private func _reload() async {
		let configuredSources = Storage.shared.getSources()
		let configuredURLs = Set(configuredSources.compactMap(\.sourceURL))
		let sources = AppUpdateChecker.configuredRepositories(
			in: Array(SourcesViewModel.shared.sources.values),
			sourceURLs: configuredURLs
		)
		await _updateChecker.precomputeAllUpdates(
			sources: sources,
			signedApps: _signedApps,
			importedApps: _importedApps
		)
		_updates = _updateChecker.pendingUpdates(
			sources: sources,
			signedApps: _signedApps,
			importedApps: _importedApps
		)
		_isLoading = false
	}
}

// MARK: - Update All progress
struct UpdateAllProgressView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var _runner = UpdateAllManager.shared

	private let _updates: [(app: ASRepository.App, sourceName: String, hasUpdate: Bool)]

	init(updates: [(app: ASRepository.App, sourceName: String, hasUpdate: Bool)]) {
		self._updates = updates
	}

	@State private var _started = false

	var body: some View {
		NavigationStack {
			List {
				Section {
					HStack {
						Label(
							_runner.isRunning
								? String.localized("Updating %lld apps…", arguments: _runner.tasks.count)
								: String.localized("%lld apps", arguments: _runner.tasks.count),
							systemImage: "arrow.triangle.2.circlepath"
						)
						Spacer()
						if _runner.isRunning { ProgressView() }
					}
				} footer: {
					if !_runner.isRunning && _started {
						Text(verbatim: _summaryLine)
					}
				}

				Section {
					ForEach(_runner.tasks) { task in
						_row(task)
					}
				}
			}
			.navigationTitle(.localized("Update All"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button(_runner.isRunning ? .localized("Cancel") : .localized("Close")) {
						if _runner.isRunning { _runner.cancel() } else { dismiss() }
					}
				}
			}
			.onAppear {
				guard !_started else { return }
				_started = true
				let tasks = _runner.makeTasks(from: _updates)
				Task {
					await _runner.run(tasks: tasks)
				}
			}
		}
	}

	private var _summaryLine: String {
		let succeeded = _runner.succeeded
		let failed = _runner.failed
		if failed == 0, succeeded == 0 {
			return .localized("Nothing was updated.")
		}
		if failed == 0 {
			return String.localized("%lld updated and queued for install.", arguments: succeeded)
		}
		return String.localized("%lld updated, %lld failed.", arguments: succeeded, failed)
	}

	@ViewBuilder
	private func _row(_ task: UpdateTask) -> some View {
		HStack(spacing: 12) {
			SourceAppIcon(app: task.app, size: 36)

			VStack(alignment: .leading, spacing: 2) {
				Text(task.app.currentName)
					.font(.subheadline.weight(.medium))
					.lineLimit(1)
				Text(task.sourceName)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			Spacer()

			_state(task.state)
		}
	}

	@ViewBuilder
	private func _state(_ state: UpdateTask.State) -> some View {
		switch state {
		case .queued:
			Text(.localized("Queued")).foregroundStyle(.secondary)
		case .downloading, .importing, .signing:
			ProgressView()
		case .finished:
			Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
		case .skipped:
			Image(systemName: "minus.circle").foregroundStyle(.secondary)
		case .failed(let message):
			HStack(spacing: 4) {
				Image(systemName: "xmark.circle.fill")
					.foregroundStyle(.red)
				Text(message)
					.font(.caption2)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}
	}
}

// MARK: - Source app icon
/// A remote app icon for an `ASRepository.App` row (the Updates list has no local bundle yet).
private struct SourceAppIcon: View {
	let app: ASRepository.App
	let size: CGFloat

	var body: some View {
		Group {
			if let url = app.iconURL {
				AsyncImage(url: url) { phase in
					switch phase {
					case .success(let image):
						image.resizable()
					default:
						Image("App_Unknown").resizable()
					}
				}
			} else {
				Image("App_Unknown").resizable()
			}
		}
		.scaledToFit()
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
	}
}
