//
//  NavigationViewWrapper.swift
//  Stars
//
//  Created by VexSign Contributors on 7.04.2025.
//

import SwiftUI

public struct NBNavigationView<Content>: View where Content: View {
	private var _title: String
	private var _mode: NavigationBarItem.TitleDisplayMode
	private var _content: Content
	private var _path: Binding<NavigationPath>?
    private var _ownsNavigationStack: Bool

	public init(
		_ title: String,
		displayMode: NavigationBarItem.TitleDisplayMode = .automatic,
        ownsNavigationStack: Bool = true,
		@ViewBuilder content: () -> Content
	) {
		self._title = title
		self._mode = displayMode
		self._content = content()
		self._path = nil
        self._ownsNavigationStack = ownsNavigationStack
	}

	/// Path-aware — single NavigationStack with programmatic navigation, avoids double nav bars.
	public init(
		_ title: String,
		displayMode: NavigationBarItem.TitleDisplayMode = .automatic,
		path: Binding<NavigationPath>,
		@ViewBuilder content: () -> Content
	) {
		self._title = title
		self._mode = displayMode
		self._content = content()
		self._path = path
        self._ownsNavigationStack = true
	}

	public var body: some View {
		Group {
            if !_ownsNavigationStack {
                _content
                    .navigationTitle(_title)
                    .navigationBarTitleDisplayMode(_mode)
            } else if let path = _path {
				NavigationStack(path: path) {
					_content
						.navigationTitle(_title)
						.navigationBarTitleDisplayMode(_mode)
				}
			} else {
				NavigationStack {
					_content
						.navigationTitle(_title)
						.navigationBarTitleDisplayMode(_mode)
				}
			}
		}
	}
}
