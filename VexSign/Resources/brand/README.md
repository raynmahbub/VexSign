# VexSign Brand

## The V·Pen

VexSign’s mark is a capital **V** that ends in a fountain nib and one signing
flourish. It reads as a V from a favicon distance and as a signing instrument at
app-icon size. The mark is white on indigo, or a single ink in monochrome use.
It is not a generic checkmark and must never be stretched, rotated or recoloured.

The vector source is [`Source/vpen-mark.svg`](Source/vpen-mark.svg). Run:

```sh
python3 Tools/Release/generate-app-icons.py
python3 Tools/Release/generate-app-icons.py --check
```

The command owns every generated raster/vector delivery below. Do not edit a
PNG, favicon, catalog copy or README GIF by hand.

## Palette

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `indigoTop` → `indigoBottom` | `#6D6AF0` → `#4B48C4` | `#7C79F5` → `#5A57D6` | Tile, app icon, primary brand surface |
| Dark app-icon ground | — | `#1E1C34` → `#0C0C14` | System dark icon appearance |
| Ink / paper | `#1D1D1F` | `#F5F5F7` | Wordmark and copy |
| Surface / muted | `#15151D` / `#6E6E73` | `#15151D` / `#A1A1AA` | Banner, GIF and metadata |

## Asset map

| Surface | Location |
| --- | --- |
| Source mark | `Source/vpen-mark.svg`, `Source/vpen-mark-1024.png` |
| iOS icon source | `../Icons/AppIcon/` — standard, light, dark and tinted 1024px variants |
| AppIcon catalog | `../Assets.xcassets/AppIcon.appiconset/` |
| Logo marks, lockups, monochrome | `Logo/` |
| Banner | `Banner/` |
| Browser/PWA package | `Favicon/` |
| GitHub/social artwork | `Social/` |
| README animation / fallback | `Motion/hero.gif`, `Motion/hero-still.png` |

## Usage rules

* **iOS owns app-icon corners.** `Icons/AppIcon/icon.png` is opaque, square and
  full-bleed. Never bake a rounded alpha mask into it.
* Use `Logo/logo-mark.svg` on light surfaces and `logo-mark-dark.svg` on dark
  ones. Use a lockup rather than manually setting “VexSign” beside the tile.
* Clear space around the tile is one quarter of the tile side. The tile is at
  least 24 px on screen; below that use the monochrome V·Pen.
* The animated hero is for README/social only. Respect reduced-motion settings
  in the native app; no app behaviour depends on the animation.
