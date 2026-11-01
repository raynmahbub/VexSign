//
//  Binding+optional.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 19.04.2025.
//

import SwiftUI

extension Binding {
	/// The same binding, projected to an optional value.
	///
	/// Reading yields the wrapped value; assigning `nil` is a no-op rather than a
	/// way to clear it, which is what the hand-rolled `get:`/`set:` pair this
	/// replaces did. SwiftUI's own projection is used because those closures are
	/// `@Sendable`, and capturing `self` (a `Binding` is only conditionally
	/// `Sendable`) in one is a concurrency warning.
	public func optional() -> Binding<Value?> {
		Binding<Value?>(self)
	}
}
