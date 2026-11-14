# Vendored packages

These packages live in the repository as ordinary local SwiftPM packages, so a
plain `git clone` and CI never need an extra checkout to build VexSign.

| Package | Upstream | Pinned commit | License |
| --- | --- | --- | --- |
| `Zsign` | [claration/Zsign-Package](https://github.com/claration/Zsign-Package) (`package`) | `6ffe703` · 2025-07-28 | MIT + Apache-2.0 component notice |
| `IDeviceKitten` | [claration/IDeviceKit](https://github.com/claration/IDeviceKit) (`main`) | `837cf1e` · 2026-04-14 | MIT |

The exact pins, paths and licence files are in [`manifest.json`](manifest.json).
`IDeviceKit`'s `Package.swift` still resolves its `IDevice` binary target from
the upstream release URL; the Swift sources and manifest are vendored here.
`Zsign`'s `Package.swift` still declares its OpenSSL SwiftPM dependency. Both
are ordinary SwiftPM dependencies. This is a source snapshot, not a completely
offline build.

## Why

- A clone builds without extra repository state, credentials or recursive fetches.
- The exact third-party source is reviewable in the same diff as the code that
  uses it.
- CI caches a stable package graph instead of depending on two extra remotes.

## Updating

1. Pick the new upstream commit.
2. Export only the files the package manifest needs into `Packages/Vendor/<Package>`:

   ```bash
   git clone https://github.com/claration/Zsign-Package.git /tmp/zsign
   git -C /tmp/zsign fetch --depth 1 origin <commit>
   rm -rf Packages/Vendor/Zsign/src Packages/Vendor/Zsign/Sources
   git -C /tmp/zsign archive <commit> src Sources Package.swift README.md LICENSE LICENSE_LC \
     | tar -x -C Packages/Vendor/Zsign
   ```

   For `IDeviceKitten`, archive `Sources Package.swift LICENSE README.md`.

3. Update the row and commit in `manifest.json` and this table.
4. Run `make verify`, then a signed device build, and note the change in
   `CHANGELOG.md`.

Do not add upstream build output, tests, `.git`, or generated artifacts.

## Layout and notices

Keep upstream package paths intact: `Sources/IDeviceSwift/` is SwiftPM target
layout, and `src/` plus `Sources/` are explicitly selected by Zsign's manifest.
The upstream `Utilties/` spelling is intentional here for snapshot fidelity; do
not rename it just to change GitHub's compact-folder display. `IDeviceKitten` is
the checkout folder, while its upstream package name remains `IDeviceKit`.

Zsign carries both `LICENSE` (MIT) and `LICENSE_LC` (Apache-2.0); preserve both.
Commit dates in the table/manifest are UTC dates. When checking a refresh, compare
file blobs with the declared upstream tree, not merely the short commit label.
Dependency/binary downloads still require network access and upstream availability.

## Local IDeviceKitten patch

The upstream pin is unchanged. `manifest.json` records a local patch and before/after
SHA-256 hashes for `Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift`.
The patch streams pairing payloads in 1 MiB chunks instead of loading the whole
IPA, scopes native byte pointers to `withUnsafeBytes`, closes remote handles on
error, throttles upload progress and forwards parent task cancellation to the
worker. Native in-progress calls are not forcibly interruptible. Upstream MIT
notices are retained. On refresh, reapply or retire this patch explicitly rather
than assuming this file is byte-identical to the pinned upstream snapshot.

`manifest.json` records a second local patch, for
`Sources/IDeviceSwift/InstallationProxy/InstallationAppProxy.swift`. Upstream
`deleteApp(for:)` connected only through the direct provider, so it could not work
on the RSD tunnel that `listApps()` supports, and it never freed the
installation-proxy client. The patch makes it check the pairing file, connect the
way `listApps()` does, and free the client on success and on error. Nothing else
in the file is changed.

Real AFC upload, transport failure, close behavior and app removal still require
device tests.
