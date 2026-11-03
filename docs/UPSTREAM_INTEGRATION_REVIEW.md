# Odysseus and embedded runtime review

Reviewed 2026-11-02. The separate combined-host source/build integration is now
implemented in [EmbeddedContainer](../EmbeddedContainer/README.md). It builds the
actual official runtime and embeds SideStore plus a bundled VexSign guest. Native
compilation and device execution remain unverified. The normal IPA is unchanged
in architecture; it does not acquire an embedded runtime through a URL launcher.

## Exact references

- Requested reference: https://github.com/mirazbakis/Odysseus
  - Reviewed master commit `2664dadedf9aca36fda0925a8aada92e2c79323f`.
  - `Feather/Views/Odysseus/ODRootView.swift`: Discover, Sources, Library,
    Settings and Search; modern Tab API, sidebar-adaptable presentation and
    iOS 26 tab-bar scroll minimization.
  - `Feather/Backend/AppleID/ODAppleIDManager.swift`: account signing through
    `import SideSign`, including certificate/App ID/device/profile operations.
    Its header explicitly calls for on-device testing.
  - `SideSign/Package.swift`: vendored AGPL-3.0 SideSign; Swift 6 and native
    crypto/signing dependencies. Some dependencies follow moving branches.
  - Odysseus is GPL-3.0; its SideSign portions carry AGPL obligations. Concepts
    are being adapted here; SideSign/account-manager source has not been copied.
- Official host: https://github.com/LiveContainer/LiveContainer
  - Reviewed main commit `9108ae624ea001f7d7696d48407f890b48fa2653`.
  - `.github/workflows/build.yml` and `.github/build_github.sh` build the host
    and generate a separate combined SideStore IPA.
  - `SideStoreSupport`, `LiveProcess/SideStoreLiveProcessHandler.m` and
    `LiveContainerSwiftUI/Models/BuiltInSideStoreAppInfo.swift` participate in
    hosting/support, rather than merely opening the SideStore URL scheme.

## What has been adapted

VexSign retains its required Home destination and uses Library / Home / App Store /
Activity / Settings as the five default destinations. Library groups apps/files;
Activity groups downloads/tasks/logs; App Store already groups catalog/sources.
Native Tab APIs provide iPad sidebar adaptability and system iOS 26 appearance.
Shared child pages explicitly reuse their workspace stack, while standalone tabs
and sheets retain their own stacks. Extra opt-in tabs no longer instantiate a
hidden overflowing UITabBarController/More navigation controller.

## What is not equivalent

Odysseus's native Apple-account signing engine is **not** the full LiveContainer
hosting runtime. Neither native tabs, imported P12 refresh, a companion URL launch,
nor an Apple-account login web page constitutes direct combined embedding.

The official combined packaging script moves SideStoreSupport back into the host,
adds app-group/URL/intent metadata, downloads SideStore, converts its executable
with `dylibify`, places the result in `SideStoreApp.framework`, copies intents and
rewrites/embeds its widget extension before packaging. The host runtime and hooks
are necessary for that transformed executable to run. Copying this packaging step
into VexSign without the host would produce an unusable or crashing artifact.

## Implemented integration and remaining validation

The upstream-derived-host architecture is implemented, not a `canImport` stub:

- Pinned upstream project and recursive submodules build the real host/support
  targets. A checked patch adds host UI installation/launch callbacks and local
  guest inbox staging without exposing account credentials.
- The official SideStore framework conversion, LC app metadata, app groups,
  URL/intent ownership and widget extension adaptation are reproduced, with
  a hash-verified immutable SideStore release-asset ID, a pinned/source-hashed
  converter compiled for the build CPU, and fail-closed ABI/file checks.
- The normal VexSign IPA is copied into the host as a marked, hash-verified guest;
  installation/updates use the native LiveContainer patch/sign/load pipeline.
- VexSign calls the loaded runtime directly for session switches/import staging.
  Unhosted builds keep their existing external-companion workflow. Unsupported
  guest BGTask registrations/scheduling are suppressed with a UI explanation;
  manual foreground automation remains available.
- The combined build is manual/build-only and retains upstream identities and
  per-target entitlements. It conflicts with stock LiveContainer's bundle ID;
  independently renamed/co-installable hosts are not implemented.

The native SideSign adapter from Odysseus is NOT separately added: in this
architecture the actual embedded SideStore owns native account login, 2FA,
provisioning and renewal. Do not confuse that with VexSign acquiring credentials.

Outstanding before calling the combined artifact working/ready: Xcode archives,
actual pinned-binary ABI inspection (blocked by sandbox release-asset egress),
real-device host/guest launches and updates, login/renewal/intents, JIT/JIT-less,
app-group/Keychain behavior and existing TLS install/certificate regression tests.
Publish corresponding source and preserve AGPL component obligations before any
public binary release. Detailed build and validation instructions are in the
integration README. The workflow deliberately does not publish a release.
