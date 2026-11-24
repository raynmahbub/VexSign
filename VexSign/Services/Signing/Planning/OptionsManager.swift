//
//  OptionsManager.swift
//  VexSign
//
//  Created by VexSign Contributors on 15.04.2025.
//

import Foundation
import Combine
import NimbleExtensions

// MARK: - OptionsManager
class OptionsManager: ObservableObject {
	static let shared = OptionsManager()

	@Published var options: Options
	private let _key = "signing_options"

	init() {
		var loadedOptions: Options
		if
			let data = UserDefaults.standard.data(forKey: _key),
			let savedOptions = try? JSONDecoder().decode(Options.self, from: data) {
			loadedOptions = savedOptions
		} else {
			loadedOptions = Options.defaultOptions
		}

		// Compatibility mode *removes* extensions, so it must never be switched on over a
		// saved choice. Older blobs that predate the key already decode to the default
		// (`Options.init(from:)`), which is all the migration this needs: forcing the flag
		// true here also overwrote an explicit "off" and silently deleted extensions the
		// user had asked to keep (#137).
		self.options = loadedOptions
		if UserDefaults.standard.data(forKey: _key) == nil {
			self.saveOptions()
		}
	}

	/// Saves options
	func saveOptions() {
		if let encoded = try? JSONEncoder().encode(options) {
			UserDefaults.standard.set(encoded, forKey: _key)
			objectWillChange.send()
		}
	}

	/// Resets options to default
	func resetToDefaults() {
		options = Options.defaultOptions
		saveOptions()
	}
}
