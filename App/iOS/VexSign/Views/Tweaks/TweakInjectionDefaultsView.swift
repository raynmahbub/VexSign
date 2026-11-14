//
//  TweakInjectionDefaultsView.swift
//  VexSign
//
//  one screen for "which tweaks go into every app I sign".
//
//  The rules already existed on `ManagedTweak` (`injectByDefault`, `autoInjectBundleIds`) and were
//  only editable one tweak at a time, from inside that tweak's detail view — which is the wrong
//  place to answer the question this screen answers: what is on, overall? Every row here is the
//  same flag the detail view edits, so nothing new is stored and nothing can get out of sync.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - Selection logic (pure, so it can be tested without a UI)

enum TweakInjectionDefaults {
	/// Case- and diacritic-insensitive match on the name, the notes and the folder's rules.
	static func matches(_ tweak: ManagedTweak, query: String) -> Bool {
		let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return true }

		let needle = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
		let haystack = [tweak.name, tweak.notes ?? ""].joined(separator: " ")
			.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
		return haystack.contains(needle)
	}

	/// Returns the tweaks with `injectByDefault` set for every match, leaving the rest untouched.
	/// Disabled tweaks are skipped: a tweak the user switched off is not silently switched on.
	static func apply(_ value: Bool, to tweaks: [ManagedTweak], matching query: String) -> [ManagedTweak] {
		tweaks.map { tweak in
			guard tweak.isEnabled, matches(tweak, query: query), tweak.injectByDefault != value else {
				return tweak
			}
			var updated = tweak
			updated.injectByDefault = value
			return updated
		}
	}
}

// MARK: - View

struct TweakInjectionDefaultsView: View {
	@ObservedObject private var manager = TweakManager.shared
	@Environment(\.dismiss) private var dismiss

	@State private var query = ""

	private var visibleTweaks: [ManagedTweak] {
		manager.tweaks
			.filter { TweakInjectionDefaults.matches($0, query: query) }
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	private var enabledCount: Int {
		manager.tweaks.filter { $0.isEnabled && $0.injectByDefault }.count
	}

	private var visibleAllOn: Bool {
		let candidates = visibleTweaks.filter { $0.isEnabled }
		return !candidates.isEmpty && candidates.allSatisfy { $0.injectByDefault }
	}

	var body: some View {
		NBNavigationView(.localized("Inject by Default")) {
			// `NBList` takes its title as an unlabelled argument — there is no title-less initialiser
			// (see NimbleViews/Views/NBList.swift), and every other sheet in this app passes the same
			// string to both the navigation view and the list.
			NBList(.localized("Inject by Default")) {
				summarySection
				if visibleTweaks.isEmpty {
					emptySection
				} else {
					tweaksSection
				}
			}
			.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(.localized("Search tweaks")))
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(.localized("Done")) { dismiss() }
						.fontWeight(.semibold)
				}
			}
		}
	}

	@ViewBuilder
	private var summarySection: some View {
		Section {
			LabeledContent(.localized("Injecting by default")) {
				Text(verbatim: String.localized("%lld of %lld", arguments: enabledCount, manager.tweaks.count))
					.monospacedDigit()
			}

			HStack(spacing: 12) {
				Button {
					_setAll(true)
				} label: {
					Label(.localized("All On"), systemImage: "checkmark.circle")
				}
				.disabled(visibleAllOn)

				Spacer()

				Button {
					_setAll(false)
				} label: {
					Label(.localized("All Off"), systemImage: "circle.slash")
				}
				.disabled(enabledCount == 0)
			}
			.buttonStyle(.borderless)
		} header: {
			Text(.localized("Signed apps"))
		} footer: {
			Text(.localized("A tweak that is on here is injected into every app you sign from now on, unless the app is listed in that tweak's exceptions. Turning one on does not sign anything; the next sign picks it up."))
		}
	}

	@ViewBuilder
	private var emptySection: some View {
		Section {
			Text(query.isEmpty
				 ? .localized("No tweaks in the library yet.")
				 : .localized("No tweak matches that search."))
				.font(.callout)
				.foregroundStyle(.secondary)
		}
	}

	@ViewBuilder
	private var tweaksSection: some View {
		Section {
			ForEach(visibleTweaks) { tweak in
				Toggle(isOn: Binding(
					get: { tweak.injectByDefault },
					set: { _set($0, for: tweak) }
				)) {
					VStack(alignment: .leading, spacing: 2) {
						Text(tweak.name)
							.lineLimit(1)

						if !tweak.isEnabled {
							Text(.localized("Disabled"))
								.font(.caption)
								.foregroundStyle(.secondary)
						} else if let exceptions = exceptionSummary(tweak) {
							Text(exceptions)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(2)
						}
					}
				}
				.disabled(!tweak.isEnabled)
			}
		} header: {
			Text(.localized("Tweaks"))
		} footer: {
			Text(.localized("Exceptions are per tweak, in the tweak's own screen."))
		}
	}

	private func exceptionSummary(_ tweak: ManagedTweak) -> String? {
		guard !tweak.autoInjectBundleIds.isEmpty else { return nil }
		if tweak.injectByDefault {
			return String.localized("Except %lld app(s)", arguments: tweak.autoInjectBundleIds.count)
		}
		return String.localized("Only %lld app(s)", arguments: tweak.autoInjectBundleIds.count)
	}

	// MARK: Actions

	private func _set(_ value: Bool, for tweak: ManagedTweak) {
		guard var updated = manager.tweaks.first(where: { $0.id == tweak.id }) else { return }
		updated.injectByDefault = value
		manager.update(updated)
	}

	private func _setAll(_ value: Bool) {
		let current = manager.tweaks
		let next = TweakInjectionDefaults.apply(value, to: current, matching: query)

		for tweak in next where current.first(where: { $0.id == tweak.id })?.injectByDefault != tweak.injectByDefault {
			manager.update(tweak)
		}

		Toast.info(
			value
				? .localized("Every matching tweak now injects by default.")
				: .localized("No matching tweak injects by default."),
			systemImage: value ? "checkmark.circle" : "circle.slash"
		)
	}
}
