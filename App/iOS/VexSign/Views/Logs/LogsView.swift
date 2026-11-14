//
//  LogsView.swift
//  VexSign
//
//  The Logs tab: one live console for everything the app does — signing, tweak injection,
//  installs, downloads, automation. Entries stream in newest first as they happen, and the
//  tail of the on-disk log is loaded behind them so opening the tab after a relaunch still
//  shows what happened last time.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct LogsView: View {
	@ObservedObject private var _log = SigningLog.shared

	/// `nil` shows everything.
	@State private var _filter: LogKind?
	@State private var _showsFilters = true

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Logs"), displayMode: .inline) {
			VStack(spacing: 0) {
				if _showsFilters {
					_filterBar
					Divider()
						.background(Color.white.opacity(0.08))
				}

				LogConsoleView(
					entries: _visible,
					showCategory: true,
					onRefresh: { _log.loadHistory(force: true) }
				)
				.overlay { _emptyState }
			}
			.background(Color(uiColor: LogConsoleView.consoleBackgroundColor))
			.ignoresSafeArea(edges: .bottom)
			.toolbar {
				NBToolbarMenu(systemImage: "ellipsis.circle", style: .icon, placement: .topBarTrailing) {
					Button(.localized("Share"), systemImage: "square.and.arrow.up") { _share() }
						.disabled(_visible.isEmpty)
					Button(.localized("Export Diagnostic Bundle"), systemImage: "archivebox") { _exportDiagnostics() }
					Button(.localized("Copy"), systemImage: "doc.on.doc") { _copy() }
						.disabled(_visible.isEmpty)
					Button(.localized("Reload"), systemImage: "arrow.clockwise") {
						_log.loadHistory(force: true)
					}
					Button(_showsFilters ? .localized("Hide Filters") : .localized("Show Filters"), systemImage: "line.3.horizontal.decrease.circle") {
						_showsFilters.toggle()
					}
					Divider()
					Button(.localized("Clear"), systemImage: "trash", role: .destructive) { _confirmClear() }
						.disabled(_log.entries.isEmpty)
				}
			}
			.toolbarBackground(Color(uiColor: LogConsoleView.consoleBackgroundColor), for: .navigationBar)
			.toolbarBackground(.visible, for: .navigationBar)
			.toolbarColorScheme(.dark, for: .navigationBar)
			.onAppear { _log.loadHistory() }
		}
	}
}

// MARK: - Filtering
extension LogsView {
	/// Everything the tab can be filtered to, in display order.
	private static let _kinds: [LogKind] = [.info, .success, .warn, .error, .detail]

	private var _visible: [LogEntry] {
		guard let filter = _filter else { return _log.entries }
		return _log.entries.filter { $0.kind == filter }
	}

	private func _count(of kind: LogKind?) -> Int {
		guard let kind else { return _log.entries.count }
		return _log.entries.filter { $0.kind == kind }.count
	}

	@ViewBuilder
	private var _filterBar: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				_chip(kind: nil, title: .localized("All"), systemImage: "list.bullet.rectangle")

				ForEach(Self._kinds, id: \.self) { kind in
					_chip(kind: kind, title: kind.title, systemImage: kind.systemImage)
				}
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
		}
		.background(Color(uiColor: LogConsoleView.consoleBackgroundColor))
	}

	@ViewBuilder
	private func _chip(kind: LogKind?, title: String, systemImage: String) -> some View {
		let isSelected = _filter == kind
		let count = _count(of: kind)

		Button {
			withAnimation(.snappy) { _filter = isSelected ? nil : kind }
		} label: {
			HStack(spacing: 5) {
				Image(systemName: systemImage)
					.font(.caption2)
				Text(title)
					.font(.caption.weight(.semibold))
				Text(count.formatted(.number.notation(.compactName)))
					.font(.caption2.monospacedDigit())
					.opacity(0.7)
			}
			.foregroundStyle(isSelected ? Color.black : _tint(for: kind))
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(
				Capsule().fill(isSelected ? _tint(for: kind) : _tint(for: kind).opacity(0.16))
			)
		}
		.buttonStyle(.plain)
		// An empty filter still has to be reachable to see that it is empty.
		.disabled(count == 0 && !isSelected)
		.opacity(count == 0 && !isSelected ? 0.4 : 1)
	}

	private func _tint(for kind: LogKind?) -> Color {
		switch kind {
		case .none: .white
		case .info: Color(red: 0.40, green: 0.64, blue: 1.00)
		case .success: Color(red: 0.34, green: 0.86, blue: 0.60)
		case .warn: Color(red: 1.00, green: 0.78, blue: 0.34)
		case .error: Color(red: 1.00, green: 0.45, blue: 0.47)
		case .detail: Color(red: 0.62, green: 0.65, blue: 0.72)
		}
	}

	@ViewBuilder
	private var _emptyState: some View {
		if _visible.isEmpty {
			VStack(spacing: 6) {
				Image(systemName: _log.entries.isEmpty ? "text.alignleft" : "line.3.horizontal.decrease.circle")
					.font(.title3)
				Text(verbatim: _log.entries.isEmpty ? String.localized("No logs yet") : String.localized("Nothing matches this filter"))
					.font(.footnote)
				if _log.entries.isEmpty {
					Text(.localized("Sign, install or download something and it shows up here as it happens."))
						.font(.caption2)
						.multilineTextAlignment(.center)
						.opacity(0.7)
				}
			}
			.foregroundStyle(.white.opacity(0.4))
			.padding(.horizontal, 32)
		}
	}
}

// MARK: - Actions
extension LogsView {
	private func _share() {
		guard !_visible.isEmpty else { return }

		let name = "VexSign-Logs-\(Self._stamp()).txt"
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

		do {
			try _log.exportText(_visible).write(to: url, atomically: true, encoding: .utf8)
			UIActivityViewController.show(activityItems: [url])
		} catch {
			Toast.error(error.localizedDescription, duration: .long)
		}
	}

	private func _exportDiagnostics() {
		guard let zipURL = DiagnosticBundleExporter.createDiagnosticBundle() else {
			Toast.error(.localized("Failed to create diagnostic bundle"), duration: .long)
			return
		}
		UIActivityViewController.show(activityItems: [zipURL])
	}

	private func _copy() {
		UIPasteboard.general.string = _log.exportText(_visible)
		Toast.success(.localized("Copied"), systemImage: "doc.on.doc")
	}

	private func _confirmClear() {
		DestructiveConfirm.present(title: .localized("Clear Logs?")) {
			_log.clear()
			Toast.success(.localized("Logs cleared"), systemImage: "trash")
		}
	}

	private static func _stamp() -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyyMMdd-HHmm"
		return formatter.string(from: Date())
	}
}
