//
//  NBList.swift
//  NimbleKit
//
//  Created by VexSign TeamSign Team on 7.05.2025.
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
		.navigationTitle(_title)
		.navigationBarTitleDisplayMode(_mode)
	}
}
