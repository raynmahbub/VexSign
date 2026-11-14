# VexSign visual identity

The existing VexSign mark is the brand: one softly embossed white V on a luminous violet field. Keep its silhouette and proportions intact. Do not add a checkmark, wordmark, extra symbol, or replacement monogram.

## Canonical assets

- `icon.png` — repository/readme icon; 1024 × 1024.
- `App/iOS/VexSign/Resources/Assets.xcassets/AppIcon.appiconset/vexsign.png` — standard iOS home-screen icon.
- `vexsign_dark.png` and `vexsign_tint.png` in that same asset set — existing dark and tinted appearances; preserve them as separate treatments of the same V.
- `App/iOS/VexSign/Resources/Assets.xcassets/AppLogo.imageset/AppLogo.png` — launch-screen logo.
- `App/iOS/VexSign/Resources/Assets.xcassets/Glyph.imageset/vexsign.png` — in-app glyph.
- `Resources/Branding/brand/liquid-glass-logo.png` — existing Liquid Glass presentation variant; keep its V contour aligned with the master.
- `Documentation/Design/assets/logo.svg` — scalable vector V for web and documentation.

The raster master files are intentionally consistent. When refreshing them, keep the original V contour and align the mark with the center of the square canvas; keep useful clear space around it.

## iOS icon rules

The AppIcon asset catalog uses 1024 × 1024 opaque square images and declares standard, dark, and tinted appearances. This is the correct source format: **do not pre-round the corners**—iOS applies the platform mask. Do not add a border, device mockup, or text. Keep the V visible after the rounded-square mask and at small home-screen sizes. Preserve the dark and tinted variants rather than copying the standard treatment over them.

## Palette

The established identity is a lavender/violet gradient with a porcelain-white V. Keep new supporting UI colors subordinate to the existing app theme; do not introduce a competing accent palette. The vector `Documentation/Design/assets/logo.svg` remains a simplified transparent-background rendition for contexts where the full icon tile is inappropriate.

## Release check

Before release, build the asset catalog with Xcode and inspect the standard, dark, and tinted icons on a device or simulator. This checkout environment can validate dimensions and catalog references, but cannot run Apple's asset catalog compiler or visual simulator check.
