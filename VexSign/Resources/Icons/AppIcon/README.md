# VexSign app icon

This is the **published iOS/web output** of the VexSign V·Pen brand system.
The only artwork source is [`../../brand/Source/vpen-mark.svg`](../../brand/Source/vpen-mark.svg).
Regenerate every derivative from the repository root:

```sh
python3 Tools/Release/generate-app-icons.py
python3 Tools/Release/generate-app-icons.py --check
```

Do not edit files in this folder directly. The generator also synchronizes the
Xcode asset catalog, `AppIcon.icon`, `LaunchLogo`, `AppLogo`, `VexMark`, the
Web Manager dashboard icon, the browser/favicon package and README animation.

## Variants

| File | Appearance | Used by |
| --- | --- | --- |
| `icon.png` | Standard indigo V·Pen | Published feed icon and standard `AppIcon.appiconset` slot |
| `icon-light.png` | Brighter indigo tile | Light-surface export |
| `icon-dark.png` | Deep ink tile | System dark icon slot |
| `icon-tinted.png` | Opaque monochrome tile | System tinted icon slot |
| `icon-512.png` / `icon-256.png` / `icon-192.png` / `icon-180.png` | Rounded web delivery | Dashboard, PWA and touch-icon consumers |
| `favicon-32.png` / `favicon-16.png` | Rounded browser delivery | Small icon consumers |

Every 1024px iOS variant is opaque RGB and has no baked corner alpha. iOS owns
the Home Screen mask.

## System mode

There is no separate “system” asset. `AppIcon.appiconset/Contents.json` declares
standard, dark and tinted slots, which the system maps automatically:

- **Light / system-light** → `icon.png`
- **Dark / system-dark** → `icon-dark.png`
- **Tinted icons** → `icon-tinted.png`

The Icon Composer source at `VexSign/Resources/AppIcon.icon/` is generated from
the same transparent V·Pen master, so it no longer drifts from the catalog.

## Published URL

Feeds and release notes use the standard icon at:

```
https://raw.githubusercontent.com/raynmahbub/VexSign/main/VexSign/Resources/Icons/AppIcon/icon.png
```

`Tools/Validation/repository-validation/check_ios_icon_assets.py` protects the
catalog-to-published-icon contract; the generator’s `--check` mode protects the
full brand suite.
