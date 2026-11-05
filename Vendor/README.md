# Vendored packages

These packages used to be Git submodules. They now live in the repository as
ordinary local SwiftPM packages, so `git clone` and CI never need
`--recursive` (or a working submodule remote) to build VexSign.

| Package | Upstream | Pinned commit | License |
| --- | --- | --- | --- |
| `Zsign` | [claration/Zsign-Package](https://github.com/claration/Zsign-Package) (`package`) | `6ffe703` · 2025-07-27 | MIT |
| `IDeviceKitten` | [claration/IDeviceKit](https://github.com/claration/IDeviceKit) (`main`) | `837cf1e` · 2026-04-14 | MIT |

The exact pins, paths and licence files are in [`manifest.json`](manifest.json).
`IDeviceKit`'s `Package.swift` still resolves its `IDevice` binary target from
the upstream release URL; the Swift sources and manifest are vendored here.

## Why

- A clone builds without Git submodule state, credentials or recursive fetches.
- The exact third-party source is reviewable in the same diff as the code that
  uses it.
- CI caches a stable package graph instead of depending on two extra remotes.

## Updating

1. Pick the new upstream commit.
2. Export only the files the package manifest needs into `Vendor/<Package>`:

   ```bash
   git clone https://github.com/claration/Zsign-Package.git /tmp/zsign
   git -C /tmp/zsign fetch --depth 1 origin <commit>
   rm -rf Vendor/Zsign/src Vendor/Zsign/Sources
   git -C /tmp/zsign archive <commit> src Sources Package.swift LICENSE LICENSE_LC \
     | tar -x -C Vendor/Zsign
   ```

   For `IDeviceKitten`, archive `Sources Package.swift LICENSE README.md`.

3. Update the row and commit in `manifest.json` and this table.
4. Run `make verify`, then a signed device build, and note the change in
   `CHANGELOG.md`.

Do not add upstream build output, tests, `.git`, or generated artifacts.
