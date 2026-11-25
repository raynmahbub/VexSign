# VexSign Brand System

VexSign uses the **V·Pen**: a capital V that becomes a fountain nib and ends in
one signing flourish. It ties the name to the product’s signing workflow while
remaining a clear V at the smallest icon sizes.

The complete generated source package lives in
[`VexSign/Resources/brand/`](../../VexSign/Resources/brand/README.md). Its
single hand-authored mark is `Source/vpen-mark.svg`; never edit generated PNG,
SVG, GIF, favicon or Xcode catalog copies by hand.

## Generate and verify

```sh
python3 Tools/Release/generate-app-icons.py
python3 Tools/Release/generate-app-icons.py --check
```

The command updates all app-icon appearances, `AppLogo`, `LaunchLogo`, the Icon
Composer layer, Web Manager icon, logo/lockup files, browser assets, social
previews, banners and the README hero GIF. It has no runtime or network
dependency beyond Pillow.

## Palette and surface use

| Token | Value | Use |
| --- | --- | --- |
| Indigo top → bottom | `#6D6AF0` → `#4B48C4` | Standard tile and primary brand surface |
| Indigo-dark top → bottom | `#7C79F5` → `#5A57D6` | Dark-page tile and motion surfaces |
| Icon dark ground | `#1E1C34` → `#0C0C14` | iOS dark appearance |
| Ink / paper | `#1D1D1F` / `#F5F5F7` | Wordmarks and copy |
| Dark surface | `#15151D` | Banner, social and README animation ground |

The native app continues to use semantic system colours for content and status;
brand indigo is identity and accent, not a status signal.

## Logo rules

- Use the complete tile on busy or photographic surfaces. Use the monochrome
  V·Pen for engraving or single-colour output.
- Keep clear space of one quarter of the tile side. Do not place the mark inside
  a second badge or recolour it.
- A tile is at least 24 px on screen. Below that, use `logo-monochrome.svg`.
- Use `logo-lockup.svg` instead of manually setting “VexSign” beside the mark.
- The README GIF is documentation/social-only. Native motion always respects
  Reduce Motion and must never be required for comprehension.
