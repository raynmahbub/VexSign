//
//  SigningOptionsDylibSharedView.swift
//  VexSign
//
//  Created by VexSign Contributors on 19.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct SigningDylibView: View {
    @EnvironmentObject private var services: AppContainer
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
        guard let contents = services.signing.bundleContents(app: app) else { return }
        _dylibs = contents.dylibs
        _dylibURLs = contents.dylibURLs
        _hiddenDylibCount = contents.hiddenDylibCount
    }
}
