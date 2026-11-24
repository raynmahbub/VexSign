//
//  NBList.swift
//  NimbleKit
//
//  Created by VexSign Contributors on 7.05.2025.
//

import SwiftUI

public struct NBList<Content>: View where Content: View {
    @Environment(\.nbWorkspaceBackground) private var background
    @Environment(\.nbWorkspaceCard) private var card
	public enum NBListType {
		case list
		case form
	}
	
	private var _title: String
	private var _mode: NavigationBarItem.TitleDisplayMode
	private var _type: NBListType
	private var _content: Content
	
	public init(
		_ title: String,
		displayMode: NavigationBarItem.TitleDisplayMode = .automatic,
		type: NBListType = .form,
		@ViewBuilder content: () -> Content
	) {
		self._title = title
		self._mode = displayMode
		self._type = type
		self._content = content()
	}
	
	public var body: some View {
		Group {
			switch _type {
			case .form:
				Form {
					_content.listRowBackground(card)
				}
			case .list:
				List {
					_content.listRowBackground(card)
				}
			}
		}
        .scrollContentBackground(.hidden)
        .background(background)
        // Every screen built on NBList gets scroll-to-dismiss for free. It used to be opt-in
        // per screen through `dismissableKeyboard()`, so a new form with a text field trapped
        // the keyboard until the user found the Done button.
        .scrollDismissesKeyboard(.interactively)
		.navigationTitle(_title)
		.navigationBarTitleDisplayMode(_mode)
	}
}
