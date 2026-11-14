//
//  NBGrid.swift
//  NimbleKit
//
//  Created by VexSign Contributors on 10.05.2025.
//

import SwiftUI

public struct NBGrid<Content>: View where Content: View {
	private var _content: Content
    private var minimumWidth: CGFloat
	
	private var _adaptiveColumns: [GridItem] {
		[GridItem(.adaptive(minimum: minimumWidth), spacing: 16)]
	}
	
	public init(minimumWidth: CGFloat = 340, @ViewBuilder content: () -> Content) {
        self.minimumWidth = max(140, minimumWidth)
		self._content = content()
	}
	
	public var body: some View {
		ScrollView {
			LazyVGrid(columns: _adaptiveColumns, spacing: 16) {
				_content
			}.padding(.horizontal)
		}
	}
}
