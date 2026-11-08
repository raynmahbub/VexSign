//
//  SigningOptionsDylibSharedView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 19.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct SigningDylibView: View {
	@State private var _dylibs: [String] = []
	@State private var _dylibURLs: [String: URL] = [:]
	@State private var _hiddenDylibCount: Int = 0
	@State private var _query = ""

	var app: AppInfoPresentable
	@Binding var options: Options?

	private var _filteredDylibs: [String] {
		_query.isEmpty ? _dylibs : _dylibs.filter { $0.localizedCaseInsensitiveContains(_query) }
	}

	var body: some View {
		NBList(.localized("Dylib Browser"), type: .list) {
			Section {
				ForEach(_filteredDylibs, id: \.self) { dylib in
					SigningToggleCellView(
						title: dylib,
						options: $options,
						arrayKeyPath: \.disInjectionFiles,
						fileURL: _dylibURLs[dylib]
					)
				}
			}
			.disabled(options == nil)

			NBSection(.localized("Hidden")) {
				Text(verbatim: .localized("%lld required system dylibs not shown.", arguments: _hiddenDylibCount))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		}
		.searchable(
			text: $_query,
			placement: .navigationBarDrawer(displayMode: .automatic),
			prompt: Text(.localized("Search Dylibs"))
		)
		.onAppear(perform: _loadDylibs)
	}
}

// MARK: - Extension: View
extension SigningDylibView {
	private func _loadDylibs() {
		guard
			let path = Storage.shared.getAppDirectory(for: app),
			let bundle = Bundle(url: path),
			!bundle.exec.isEmpty,
			let executable = TweakImportSupport.containedRegularFile(path.appendingPathComponent(bundle.exec), in: path)
		else { return }

		let allDylibs = MachOReader.dylibs(forExecutableAt: executable)

		_dylibs = allDylibs.filter { $0.hasPrefix("@rpath") || $0.hasPrefix("@executable_path") }
		_hiddenDylibCount = allDylibs.count - _dylibs.count
		_dylibURLs = _resolveURLs(for: _dylibs, appRoot: path)
	}

	/// `@rpath/X` lives under `Frameworks/`, `@executable_path/X` under the app root anything else is skipped.
	private func _resolveURLs(for dylibs: [String], appRoot: URL) -> [String: URL] {
		var resolved: [String: URL] = [:]
		for dylib in dylibs {
			if let candidate = TweakImportSupport.resolvedDylibURL(dylib, in: appRoot) {
				resolved[dylib] = candidate
			}
		}
		return resolved
	}
}
