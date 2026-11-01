//
//  NBListAdaptable.swift
//  NimbleKit
//
//  Created by VexSign TeamSign Team on 7.05.2025.
//

import SwiftUI

public struct NBListAdaptable<Content>: View where Content: View {
    public enum Layout: Equatable { case automatic, list, grid }
    @Environment(\.nbWorkspaceBackground) private var background
    @Environment(\.nbWorkspaceCard) private var card
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var layout: Layout
    private var minimumCardWidth: CGFloat
	
	private var _content: Content
	
	public init(layout: Layout = .automatic, minimumCardWidth: CGFloat = 340, @ViewBuilder content: () -> Content) {
        self.minimumCardWidth = minimumCardWidth
        self.layout = layout
		self._content = content()
	}
	
	public var body: some View {
		if layout == .list || (layout == .automatic && horizontalSizeClass == .compact) {
			List {
				_content.listRowBackground(card)
			}
			.listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(background)
		} else {
			NBGrid(minimumWidth: minimumCardWidth) {
				_content
			}
            .background(background)
		}
	}
}
