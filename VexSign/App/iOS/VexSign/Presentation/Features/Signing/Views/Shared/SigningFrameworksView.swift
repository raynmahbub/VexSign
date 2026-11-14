//
//  SigningFrameworksView.swift
//  VexSign
//
//  Created by VexSign Contributors on 20.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct SigningFrameworksView: View {
    @EnvironmentObject private var services: AppContainer
	@State private var _frameworks: [String] = []
	@State private var _plugins: [String] = []
	@State private var _appPath: URL?
	@State private var _query = ""

	private let _frameworksPath = "Frameworks"
	private let _pluginsPath = "PlugIns"

	var app: AppInfoPresentable
	@Binding var options: Options?

	private var _filteredFrameworks: [String] {
		_query.isEmpty ? _frameworks : _frameworks.filter { $0.localizedCaseInsensitiveContains(_query) }
	}

	private var _filteredPlugins: [String] {
		_query.isEmpty ? _plugins : _plugins.filter { $0.localizedCaseInsensitiveContains(_query) }
	}

	// MARK: Body
	var body: some View {
		NBList(.localized("Frameworks & PlugIns")) {
			Group {
				if !_filteredFrameworks.isEmpty {
					NBSection(_frameworksPath) {
						ForEach(_filteredFrameworks, id: \.self) { framework in
							SigningToggleCellView(
								title: "\(self._frameworksPath)/\(framework)",
								options: $options,
								arrayKeyPath: \.removeFiles,
								fileURL: _fileURL(in: _frameworksPath, name: framework)
							)
						}
					}
				}

				if !_filteredPlugins.isEmpty {
					NBSection(_pluginsPath) {
						ForEach(_filteredPlugins, id: \.self) { plugin in
							SigningToggleCellView(
								title: "\(self._pluginsPath)/\(plugin)",
								options: $options,
								arrayKeyPath: \.removeFiles,
								fileURL: _fileURL(in: _pluginsPath, name: plugin)
							)
						}
					}
				}

				if
					_filteredFrameworks.isEmpty,
					_filteredPlugins.isEmpty {
					Text(.localized("No Frameworks or PlugIns Found."))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			}
			.disabled(options == nil)
		}
		.searchable(
			text: $_query,
			placement: .navigationBarDrawer(displayMode: .automatic),
			prompt: Text(.localized("Search Frameworks"))
		)
		.onAppear(perform: _listFrameworksAndPlugins)
	}
}

// MARK: - Extension: View
extension SigningFrameworksView {
	private func _listFrameworksAndPlugins() {
        guard let contents = services.signing.bundleContents(app: app) else { return }
        _appPath = contents.appURL
        _frameworks = contents.frameworks
        _plugins = contents.plugins
    }

	private func _fileURL(in subpath: String, name: String) -> URL? {
		_appPath?.appendingPathComponent(subpath).appendingPathComponent(name)
	}
}
