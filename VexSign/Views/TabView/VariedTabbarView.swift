//
//  VariedTabbarView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 11.04.2025.
//
import SwiftUI

/// The app uses one tab implementation on every supported iOS version.
///
/// The iOS 18 sidebar-adaptable `Tab` API is useful for an iPad sidebar, but it
/// is also stateful and can lose its selection when a tab contains another
/// navigation stack. App Store is a particularly expensive tab to recreate, so
/// switching between the two implementations caused the blank/crash-like
/// behaviour users saw. The classic `TabView(selection:)` below is stable on
/// iOS 16 through the latest SDK and still adapts naturally on iPad.
struct VariedTabbarView: View {
    var body: some View {
        TabbarView()
    }
}
