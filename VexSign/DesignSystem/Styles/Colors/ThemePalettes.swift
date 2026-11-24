//
//  ThemePalettes.swift
//  VexSign
//
//  Named palettes that are not part of the general surface tokens.
//

import SwiftUI

/// Palettes for surfaces that need their own colours: a fixed dark console, the download
/// overlay's presets, the Flare presentation, and the accents that tell file roots and setup
/// tiles apart.
///
/// These values used to sit inline in the views that drew them — the log palette twice, once in
/// SwiftUI and once in `UIColor`, which is how the two drifted apart; the overlay's four
/// background colours in both the SwiftUI overlay and its UIKit sheet controller; and the
/// Flare palette inside `HomeFlareComponents`. `test_color_policy.py` now fails a colour literal
/// outside `VexSign/DesignSystem/Colors`, so the next one has to be named here first.
extension Theme {
    /// The log console keeps a fixed dark surface in both appearances, so its contrast is
    /// chosen once rather than inherited.
    enum Console {
        static let background = Color(white: 0.095)
        static let text = Color(red: 0.90, green: 0.91, blue: 0.96)
        static let dim = Color(red: 0.62, green: 0.65, blue: 0.72)
        static let meta = Color(red: 0.56, green: 0.60, blue: 0.72)
        static let success = Color(red: 0.34, green: 0.86, blue: 0.60)
        static let warning = Color(red: 1.00, green: 0.78, blue: 0.34)
        static let error = Color(red: 1.00, green: 0.45, blue: 0.47)
    }

    /// Log levels on a light surface — the Logs screen, which is not the console.
    enum LogLevel {
        static let info = Color(red: 0.40, green: 0.64, blue: 1.00)
        static let success = Color(red: 0.34, green: 0.86, blue: 0.60)
        static let warning = Color(red: 1.00, green: 0.78, blue: 0.34)
        static let error = Color(red: 1.00, green: 0.45, blue: 0.47)
        static let detail = Color(red: 0.62, green: 0.65, blue: 0.72)
    }

    /// The download overlay's background presets and the card that floats above them.
    enum Overlay {
        static let greyish = Color(uiColor: UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0))
        static let darkGrey = Color(uiColor: UIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0))
        /// AMOLED black: the pixels are off, not merely dark.
        static let amoled = Color(uiColor: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
        static let card = Color(uiColor: UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0))
    }

    /// The Flare presentation's own colours. `FlarePalette` decides *when* each applies; the
    /// values live here so both stay in one file with the rest of the palette.
    enum Flare {
        static let background = Color(red: 0.025, green: 0.022, blue: 0.045)
        static let card = Color(red: 0.065, green: 0.065, blue: 0.095)
        static let grid = Color(red: 0.42, green: 0.025, blue: 0.19)
        static let muted = Color(red: 0.49, green: 0.47, blue: 0.55)
        static let pink = Color(red: 1.0, green: 0.12, blue: 0.34)
        static let purple = Color(red: 0.62, green: 0.20, blue: 1.0)
        static let green = Color(red: 0.03, green: 0.76, blue: 0.50)
    }

    /// Accents that identify a file root or a setup tile. They are deliberately outside the
    /// tint: two roots side by side have to read as different places.
    enum Accent {
        static let mint = Color(red: 0.36, green: 0.78, blue: 0.58)
        static let orange = Color(red: 0.96, green: 0.56, blue: 0.32)
        static let documents = Color(red: 0.0, green: 0.48, blue: 1.0)
        static let downloads = Color(red: 0.12, green: 0.65, blue: 0.95)
        static let archives = Color(red: 0.55, green: 0.36, blue: 0.96)
        static let certificates = Color(red: 0.20, green: 0.66, blue: 0.44)
        static let signed = Color(red: 0.95, green: 0.55, blue: 0.15)
        static let tweaks = Color(red: 0.96, green: 0.33, blue: 0.26)
    }

    /// Colours that distinguish log categories. They are `UIColor` because the log renderer is
    /// UIKit — `LogPresentation.color(forCategory:)` feeds attributed text, not a SwiftUI view.
    enum LogPhase {
        static let sign = UIColor(red: 0.40, green: 0.64, blue: 1.00, alpha: 1)
        static let analyze = UIColor(red: 1.00, green: 0.69, blue: 0.30, alpha: 1)
        static let inject = UIColor(red: 0.78, green: 0.58, blue: 1.00, alpha: 1)
        static let install = UIColor(red: 0.35, green: 0.80, blue: 0.76, alpha: 1)
        static let update = UIColor(red: 1.00, green: 0.55, blue: 0.72, alpha: 1)
        static let other = UIColor(red: 0.65, green: 0.65, blue: 0.70, alpha: 1)
    }

    /// The app store banner's gradient, and the shadow it casts.
    enum Banner {
        static let start = Color(red: 0.04, green: 0.36, blue: 0.95)
        static let middle = Color(red: 0.20, green: 0.52, blue: 1.0)
        static let end = Color(red: 0.45, green: 0.20, blue: 0.95)
    }
}
