//
//  AppEnvironment.swift
//  VexSign
//
//  The app's single dependency-injection point.
//

import SwiftUI

/// Injects the container and the stores built from it, once.
///
/// The scene and the install-queue window each used to spell the chain out — eighteen
/// `environmentObject` calls in `VexSignApp`, and fifteen more (wrapped onto one line, four
/// containers deep) for the window `AppContainer` builds. A store added to the container had to
/// be added to both, and the failure mode for forgetting was not a compile error: the window
/// opened and crashed on first access with "No ObservableObject of type … found".
///
/// Two ways to read a dependency, in order of preference:
///
/// * `@Environment(\.appContainer) private var container` — the whole graph, no per-type lookup,
///   and what new code should use.
/// * `@EnvironmentObject private var services: AppContainer` — the same object, for the views
///   that already had it.
///
/// The individual stores stay injected because 26 views ask for one directly (`tasks`, `files`,
/// `viewModel`). `test_environment_injection_policy.py` fails a store injected with
/// `.environmentObject(container.…)` anywhere else, so a third chain cannot appear.
struct AppEnvironment: ViewModifier {
	let container: AppContainer
	/// The appearance store is owned by the scene as a `StateObject`; the install-queue window
	/// has no appearance state of its own and passes nothing.
	var appearance: AppearanceStore?

	func body(content: Content) -> some View {
		content
			.environmentObject(container)
			.environmentObject(container.cloudConfiguration)
			.environmentObject(container.tasks)
			.environmentObject(container.appleAccount)
			.environmentObject(container.workspace)
			.environmentObject(container.sources)
			.environmentObject(container.certificates)
			.environmentObject(container.signingPreferences)
			.environmentObject(container.discovery)
			.environmentObject(container.installationQueue)
			.environmentObject(container.files)
			.environmentObject(container.tweaks)
			.environmentObject(container.entitlements)
			.environmentObject(container.repositoryBuilder)
			.environmentObject(container.fileBrowser)
			.environment(\.appContainer, container)
			.environmentObject(appearance ?? AppearanceStore.shared)
	}
}
