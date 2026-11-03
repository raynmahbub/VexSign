# Screenshot stabilization pass

## Changes in this branch

- Archive validation compares canonical filesystem components without directory URL
  sentinels; `Payload/` is accepted while parent, absolute, drive-style and symlink
  escapes remain rejected. All three ZIP extraction callers now supply the actual
  extraction destination, not the directory holding the downloaded archive.
  Added a real ZIP fixture test with explicit Payload directory entries.
- Default tabs are Library, Home, App Store, Activity and Settings. Files is an
  optional tab. Preference schema v2 migrates the old mandatory Files destination
  without losing future explicit opt-in choices. Fresh installs hide secondary tabs.
- Up to five destinations use the native system tab bar (real Liquid Glass and
  scroll minimization on iOS 26, native compatibility appearance on older versions).
  More than five optional destinations retain the custom overflow-safe shell.
  Removed the global animation on every tab selection; custom animation honors
  Reduce Motion. The download badge now observes download changes directly.
- Local HTTPS readiness requires system trust, not just an identity file. The
  trust check uses the system store with network fetching disabled; it does NOT
  add the app's CA as an anchor. Readiness refreshes when returning from Settings.
- Local TLS errors now explain profile installation and Full Trust, without the
  obsolete certificate-download/DNS instructions. No SSL verification bypass and
  no silent CA replacement were added.
- An unconfirmed/absent installed-app probe no longer asserts that iOS definitely
  rolled back an app or that signing is conclusively the cause.
- Certificate persistence no longer immediately starts an OCSP refresh and a
  repository-widget icon refresh in the save callback. The status-only widget
  refresh is deferred until after completion; list/manual status checks remain.
  This reduces import-time work; it is NOT a confirmed fix for an OS-level crash.

## Still needs evidence / validation

- Run CI full and the native archive, navigation and install-preflight tests.
  Linux repository checks and Swift grammar parsing are not native type checking.
- Reproduce the exact supplied IPA import and both installation failures on device.
  Profile installation/full trust must be performed by the user in system Settings.
- Supply the certificate-import `.ips` crash report (Settings → Privacy & Security →
  Analytics & Improvements → Analytics Data). Do not include P12s, passwords or keys.
  The screenshots alone cannot identify the crashing stack or a jetsam termination.
- Duplicate navigation stacks in pushed Task Center pages and the extra-tab
  UIKit More-controller path have now been removed. Shared workspace pages use
  explicit navigation ownership, not an environment flag that would leak into
  sheets. Reproduce the screenshot's exact Settings/install route on device;
  eliminating these structural causes is not runtime confirmation of that report.
- The exact supplied Odysseus repository has been reviewed. See
  [upstream integration review](UPSTREAM_INTEGRATION_REVIEW.md) for the distinction
  between its SideSign signing engine and the official LiveContainer runtime.
- A separate upstream-derived combined host build is now implemented in
  `EmbeddedContainer/`: actual runtime targets, SideStore dylib/widget/intent
  packaging, bundled VexSign guest installation, direct process-local runtime
  controls and local guest import. See its README for architecture and limits.
  No native archive or device execution is verified yet; source implementation
  must not be described as a tested combined IPA. Normal builds retain companion
  handoff rather than advertising a runtime they do not contain.

## Follow-up workspace organization

- Library groups Apps and Files; Activity groups Downloads, Tasks and Logs.
  Home, App Store and Settings complete the five defaults. Existing source
  browsing remains in App Store. Optional standalone destinations remain opt-in.
- Native iOS 18+ Tab APIs use sidebar-adaptable presentation on iPad; iOS 26
  retains real system Liquid Glass and scroll minimization. Older supported OS
  versions keep the legacy native five-item TabView.
- Legacy Files links open Library/Files; Downloads links open Activity/Downloads.
  Activity, Tasks and Logs URL routes now select the appropriate Activity page.
  Workspace selections are observed centrally, not encoded as extra default tabs.
- Optional extra-tab roots are created on first visit and retained, rather than
  constructing an overflowing system tab controller with a hidden More screen.
- Quick-folder rows use stable path identities instead of newly generated UUIDs.
- Regression tests cover explicit child navigation ownership, route aliases and
  workspace selection. These are written but not natively executed in Linux.
