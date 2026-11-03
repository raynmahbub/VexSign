# VexSign + official LiveContainer + SideStore

> **Experimental prototype, not the final all-in-one architecture.** This makes
> VexSign a guest. The accepted target is VexSign as the primary host, with native
> account/certificate signing behind one interface. Do not ship this prototype as
> fulfillment of that goal. See [the architecture decision](../docs/NATIVE_SIGNING_ARCHITECTURE.md).

## Architecture implemented

This is a **separate combined host build**, not a URL launcher or a replacement
for the normal VexSign IPA. It builds the actual upstream LiveContainer targets
(including runtime hooks, LiveContainerShared, LiveContainerSwiftUI,
SideStoreSupport, LiveProcess, LaunchAppExtension and ShareExtension).

The official combined-packaging layout is reproduced with pinned inputs:
SideStore is converted to `MH_DYLIB` with `dylibify`, embedded as
`Frameworks/SideStoreApp.framework`, given upstream `LCAppInfo.plist`, and its
widget/intents are adapted to SideStoreSupport. The compiled host contains the
normal VexSign IPA as a **bundled, locally installable guest**, not an externally
installed second app. A host panel verifies its digest and installs/updates it
through LiveContainer's existing patch/sign pipeline. Guest updates use the
upstream replacement prompt, retaining the selected data container.

VexSign's combined-build UI calls the loaded `LCSharedUtils` class **directly** to
switch to the host or built-in SideStore. There is no `UIApplication.openURL`
fallback in that bridge. Guest IPA import validates ZIP metadata off the UI
thread, stages a local copy in the host inbox and switches back to the host for
explicit import. Only guest-local regular `.ipa` files can be staged. A previous
pending import must be completed/discarded first. Account credentials and signing
identities are never transferred by this API.

## Current validation status

The source/build integration and dependency-free packaging regressions are
implemented. **No native archive or device execution has been completed in this
Linux sandbox. Do not describe the combined app as tested, production-ready or
compatible with every iOS/JIT mode.** GitHub release-asset downloads are blocked
by this sandbox's egress policy, so the pinned SideStore binary's actual contents
and intent ABI must be checked by the native build. The packager fails closed if
required files/ABI markers are absent; it does not silently ship a partial host.

## Build (macOS, Xcode 26.2+)

```sh
git submodule update --init --recursive
brew install ldid
# gh must be authenticated normally; never embed a token in source/arguments.
make VexSign
python3 EmbeddedContainer/build.py --vexsign-ipa packages/VexSign.ipa
```

Or manually run **Guest-host prototype · build only** on the desired branch. It has
read-only permissions, no publish job and no automatic triggers. It does not
require Apple-account/signing/TLS secrets. Its artifact is explicitly labelled
unvalidated. The normal release workflow remains unchanged.

Outputs (ignored by Git):

- `packages/VexSign+LiveContainer+SideStore.ipa`
- `packages/VexSign+LiveContainer+SideStore.integration-sources.tar.gz`

The packager checks every cached asset's SHA-256 before executing/extracting it.
The SideStore asset ID, commit hashes and converter source digest are in
`inputs.lock.json`; no floating nightly URL is used. `dylibify` is compiled from
its pinned, SHA-256-checked source using the selected Xcode's macOS SDK, so the
converter matches the runner CPU rather than requiring a prebuilt tool binary. Deleted/replaced upstream assets cause a failure. Refresh locks only after
reviewing the matching source, binary hash, intent ABI and runtime compatibility.
The source checkout is patched with `git apply --check` before building.

## Installation / first run

1. Re-sign/install the combined **host IPA** using the official LiveContainer
   supported workflow. The package carries ad-hoc signatures and placeholder
   entitlement identities, not an Apple-authorized provisioning profile. It
   cannot grant unavailable entitlements or evade free-account restrictions.
2. The installed app is named **VexSign Container**. Configure host signing/JIT as
   required by upstream. Its built-in SideStore button opens the embedded app;
   complete SideStore's own account, anisette/2FA, pairing/VPN and renewal setup.
3. On the host Apps page choose **Install embedded VexSign**, then **Open VexSign**.
   Installation/signing errors remain visible. Adding an unsigned guest is not
   proof that it can run. This deliberate first-run step avoids silently
   replacing user data or hiding required host setup.
4. Inside VexSign use Settings → SideStore & LiveContainer for built-in session
   controls. Finish active tasks before switching: the host restarts the process.
5. To import another guest, prepare/select an IPA there and use **Import prepared
   IPA into embedded LiveContainer**. On returning to the host choose **Import IPA
   prepared in VexSign**. Discarding removes only the validated host inbox copy.

## Identities, entitlements and limitations

- The host keeps **`com.kdt.livecontainer`**, upstream extension identifiers,
  SideStore/AltStore app groups, keychain groups and schemes. This deliberately
  preserves runtime/SideStore assumptions instead of merely renaming a bundle.
  **It replaces/conflicts with a stock LiveContainer installation using that
  identity.** Back up data first. The normal `com.vexsign.app` installation remains
  separate. An independently co-installable renamed host is not implemented.
- Host and extension entitlement templates come from the pinned upstream source.
  Packaging expands placeholder identities and ad-hoc-signs Mach-O leaves, then
  applies the proper per-host/per-extension template. The authorized installer
  must rewrite/re-sign them for the user's actual team/profile. No credentials
  are present in the package.
- VexSign initially uses the main-process guest mode, not LiveProcess multitask.
  Direct controls are detected only in the patched primary combined host. Do not
  assume equivalent behavior in extension-hosted or arbitrarily renamed copies.
- Guest app groups/keychain/data are governed by upstream isolation hooks.
  Guest isolation is implemented by runtime hooks, **not an OS security boundary**
  against malicious guests in a shared host process. Run only trusted guests;
  do not assume hooks protect account secrets against hostile native code. The
  container build is **not** a migration of an existing standalone VexSign data
  directory. Export/import backups deliberately; certificates require their own
  secure import. No automatic sharing of Apple-account sessions is added.
- VexSign guest widget/watch/App Clip extensions are removed from the embedded
  guest copy: iOS cannot install them as guest extensions. The combined host
  retains the actual SideStore widget and LiveContainer extensions. Normal
  VexSign builds retain their original extensions.
- VexSign BGTask registration/scheduling is disabled in the guest build: an OS
  task launch would restart the host without the guest's launch handlers. The
  Automation screen explains this; manual foreground automation remains usable.
  Finish downloads/signing before switching sessions. Do not promise normal
  standalone background-task delivery across host/guest process restarts.
- Device-local TLS identities/trust requirements are unchanged; no TLS material
  is bundled. Installation of other apps still requires a supported installer
  and authorized signing. SideStore renewal does not promise unattended guest
  refresh or make every IPA compatible with container loading.

## Licenses and distribution

LiveContainer and its SideStore fork are **AGPL-3.0** at the pinned revisions.
`LICENSE` here retains upstream's AGPL text; standalone VexSign's GPL-3.0 notices
remain unchanged. The combined work must be distributed consistently with the
AGPL/GPL component requirements (GPLv3 section 13 permits this combination).
Bundled `VexSignSources` contains component license texts, input/source commits,
transitive host submodule revisions and integration instructions. The separate
integration-source artifact contains this directory and provenance/notices.

That small artifact is **not a substitute for all Corresponding Source**. Before
public distribution, publish accessible complete corresponding sources for the
exact VexSign revision, patched host, SideStore revision, submodules/dependencies,
build scripts and any modifications; preserve all component notices and satisfy
applicable AGPL source-offer/network obligations. Do not upload only the IPA or
rename the runtime as proprietary code. The manual workflow intentionally does
not create a release.

## Validation before calling this complete on-device

- Xcode archive of both VexSign and the patched host; verify asset hashes,
  SideStore intent metadata, required frameworks/extensions, entitlements and
  final IPA structure (packager enforces structural checks).
- Fresh install, signing/JIT setup, first guest installation, launch, process
  switch in both directions, crash recovery and update retaining guest data.
- Embedded SideStore login/2FA/cancellation, account expiry, pairing/VPN, signed
  app installation, refresh intent/widget and background behavior.
- Local IPA staging/import/discard/retry and rejection of malicious ZIP paths,
  links, duplicate entries and oversized archives.
- Guest Keychain/app-group access, document/file picker, normal certificate
  import, device-local TLS/full-trust setup and normal app installation.
- Verify existing standalone builds/data are unaffected. Certificate-import
  crash diagnostics from the original report are still required separately.
