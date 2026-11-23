//
//  ThemeTypography.swift
//  VexSign
//
//  The app's type scale. Semantic styles only, so text grows with Dynamic Type.
//

import SwiftUI

extension Theme {
    /// The app's type scale.
    ///
    /// `ACCESSIBILITY.md` says body text uses a semantic style and that a fixed point size is
    /// only right for a glyph or numeral inside a fixed frame — but 145 call sites spelled their
    /// size in points, and `.font(.caption)` does not grow when the user turns text up.
    /// Sizes that match a system style's default (`11` `caption2`, `12` `caption`, `13`
    /// `footnote`, `15` `subheadline`, `16` `callout`, `17` `body`, `20` `title3`, `22`
    /// `title2`, `28` `title`, `34` `largeTitle`) are now that style, so they render identically
    /// at the default setting and scale for everyone else.
    ///
    /// What is left here is the handful of compositions the app repeats — a screen title, a row
    /// title, tabular metadata, monospaced identifiers — that a bare style alone cannot express.
    enum Typography {
        /// A screen's own heading, matching the rounded look of the icon and the greeting.
        static let screenTitle = Font.system(.title2, design: .rounded).weight(.bold)

        /// The primary line of a list row.
        static let rowTitle = Font.body.weight(.semibold)

        /// Counts, dates and other tabular metadata.
        static let metadata = Font.caption.monospacedDigit()

        /// Bundle identifiers, URLs, paths and other copyable identifiers.
        static let identifier = Font.system(.caption, design: .monospaced)
    }
}
