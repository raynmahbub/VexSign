//
//  EmptyStateView.swift
//  VexSign
//
//  One empty state, with the spacing, glyph size and announcement decided once.
//

import SwiftUI

/// The screen that says "there is nothing here, and here is what to do about it".
///
/// Six screens hand-rolled this shape — an icon, a title in one style, a message in another, an
/// optional button, and a `VStack` spacing chosen per file — so the same idea looked slightly
/// different depending on which tab you were on, and only some of them were announced as a
/// single element. The icon sizes had drifted to `title3`, `44` and `48` points as well.
///
/// The glyph uses a Dynamic Type style rather than a point size, so it grows with the text it
/// sits above; the copy is combined into one accessibility element so VoiceOver reads "No
/// downloads, download apps from the App Store tab…" instead of three disconnected fragments.
struct EmptyStateView: View {
	/// Where the state is drawn, which decides its colours.
	enum Tone {
		/// A list or card on a normal surface.
		case standard
		/// The subject of the screen: the accent colour, larger glyph.
		case accent
		/// The fixed dark log console, where `.secondary` would be invisible.
		case onDark
	}

	let systemImage: String
	let title: String
	var message: String?
	var tone: Tone = .standard
	/// A smaller glyph for an inline row, rather than a whole empty screen.
	var compact = false
	var action: (title: String, systemImage: String, tint: Color, perform: () -> Void)?

	var body: some View {
		VStack(spacing: compact ? 6 : 12) {
			Image(systemName: systemImage)
				.font(compact ? .title3 : .largeTitle)
				.foregroundStyle(glyphColor)

			Text(verbatim: title)
				.font(compact ? .footnote : .headline)
				.foregroundStyle(textColor)
				.multilineTextAlignment(.center)

			if let message {
				Text(verbatim: message)
					.font(compact ? .caption2 : .subheadline)
					.foregroundStyle(messageColor)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
			}

			if let action {
				Button {
					action.perform()
				} label: {
					HStack(spacing: 6) {
						Image(systemName: action.systemImage)
						Text(verbatim: action.title)
					}
					.font(.subheadline.weight(.semibold))
				}
				.buttonStyle(.borderedProminent)
				.tint(action.tint)
				.padding(.top, 4)
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, compact ? 8 : 18)
		.padding(.horizontal, compact ? 8 : 24)
		.accessibilityElement(children: .combine)
	}

	private var glyphColor: Color {
		switch tone {
		case .standard: Theme.secondary
		case .accent: Theme.tint
		case .onDark: Theme.Console.dim
		}
	}

	private var textColor: Color {
		switch tone {
		case .standard: Theme.primary
		case .accent: Theme.primary
		case .onDark: Theme.Console.dim
		}
	}

	private var messageColor: Color {
		switch tone {
		case .standard: Theme.secondary
		case .accent: Theme.secondary
		case .onDark: Theme.Console.meta
		}
	}
}
