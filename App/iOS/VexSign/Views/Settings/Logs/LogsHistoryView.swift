//
//  LogsHistoryView.swift
//  VexSign
//
//  Single navigation bar: shares parent NavigationStack when pushed via NavigationLink.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct LogsHistoryView: View {
	var inNavigationStack: Bool = false
	@State private var _entries: [LogEntry] = []

	// MARK: Body
	var body: some View {
		if inNavigationStack {
			NBNavigationView(.localized("Activity Logs"), displayMode: .inline) {
				_consoleContent
			}
		} else {
			_consoleContent
		}
	}

	@ViewBuilder
	private var _consoleContent: some View {
		LogConsoleView(entries: _entries, showCategory: true, onRefresh: _load)
			.navigationTitle(.localized("Activity Logs"))
			.navigationBarTitleDisplayMode(.inline)
			.background(Color(uiColor: LogConsoleView.consoleBackgroundColor))
			.ignoresSafeArea(edges: .bottom)
			.overlay {
				if _entries.isEmpty {
					Text(.localized("No logs yet"))
						.font(.footnote)
						.foregroundStyle(.white.opacity(0.35))
				}
			}
			.toolbar {
				NBToolbarMenu(systemImage: "ellipsis.circle", style: .icon, placement: .topBarTrailing) {
					Button(.localized("Share"), systemImage: "square.and.arrow.up") {
						UIActivityViewController.show(activityItems: [FileLogger.logFileURL])
					}
					.disabled(_entries.isEmpty)
					Button(.localized("Refresh"), systemImage: "arrow.clockwise") { _load() }
					Divider()
					Button(.localized("Clear"), systemImage: "trash", role: .destructive) {
						SigningLog.shared.clear()
						_entries = []
					}
				}
			}
			.onAppear(perform: _load)
			.toolbarBackground(Color(uiColor: LogConsoleView.consoleBackgroundColor), for: .navigationBar)
			.toolbarBackground(.visible, for: .navigationBar)
			.toolbarColorScheme(.dark, for: .navigationBar)
	}

	private func _load() {
		DispatchQueue.global(qos: .userInitiated).async {
			let entries = LogParser.parseFile(FileLogger.readAll(), limit: 2000)
			DispatchQueue.main.async { _entries = entries }
		}
	}
}
