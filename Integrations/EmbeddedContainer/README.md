# VexSign + official LiveContainer + SideStore

> **Experimental, not production-ready.** The build now supports a native-primary
> candidate and the older guest-host prototype. Neither is device-accepted.
> Native account/CMS promotion and unattended renewal remain separately gated.

## Native-primary candidate (default build mode)

`--mode native-primary` embeds VexSign as a native code image exporting
`VexSignPrimaryMain`. The pinned LC bootstrap invokes this entry point directly
on normal launch, **without** `invokeAppMain`, guest bundle/home/defaults
substitution, guest Keychain hooks, or installing a VexSign guest. VexSign owns
its normal app delegate and foreground UI. Its buttons explicitly request the LC
UI or embedded SideStore session; the LC panel has **Return to VexSign**.

The bootstrap, runtime, extension identities and `com.kdt.livecontainer` identity
remain upstream-compatible. The app displays as **VexSign** but replaces/conflicts
with stock LiveContainer using that identity; it does not migrate another
standalone VexSign installation's accounts/data. The native default Keychain
access group is the host application identity, placed before upstream guest
slots. No guest-storage permission check is disabled.

Packaging requires a freshly compiled standalone **device** IPA with the native
entry symbol exported. It rejects guest/simulator inputs and mismatched native
framework/resource revisions instead of overwriting dependencies. It records and
checks the final, ad-hoc-signed primary-image hash. An incompatible primary image
fails at bootstrap; it does not silently fall back to a guest.

This candidate retains the combined runtime/SideStore extension and intent
layout. Standalone VexSign widget, Watch/App Clip extensions and standalone
AppIntent metadata are **not exported** in the combined package. Ordinary
standalone-IPA self-updates are blocked; install a verified combined-host update.
Native archive, dyld dependency compatibility, actual Apple-authorized signing,
background delivery across session switches, and device execution all still
require validation. Structural/mock tests are not proof of these properties.

```sh
make VexSign
APP_VERSION="$(grep -m1 -oE 'MARKETING_VERSION = [^;]+' VexSign.xcodeproj/project.pbxproj | awk '{print $3}')"
VEXSIGN_IPA="packages/VexSign-${APP_VERSION}.ipa"
python3 Integrations/EmbeddedContainer/build.py --mode native-primary --vexsign-ipa "$VEXSIGN_IPA"
# Reproduce the older explicitly isolated guest-host prototype:
python3 Integrations/EmbeddedContainer/build.py --mode guest-prototype --vexsign-ipa "$VEXSIGN_IPA"
```

Choose `host_mode` in **Combined native host · build only**. Path-filtered PR/main
changes also run its native-primary validation, including synthetic native unit
regressions, reusing the same workflow instead of adding another build system.
Jobs run only for public repositories with read-only permissions. Artifacts are
labelled by mode, retained 14 days, and never auto-published; logs remain 3 days.

## Guest-prototype architecture

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
APP_VERSION="$(grep -m1 -oE 'MARKETING_VERSION = [^;]+' VexSign.xcodeproj/project.pbxproj | awk '{print $3}')"
python3 Integrations/EmbeddedContainer/build.py --vexsign-ipa "packages/VexSign-${APP_VERSION}.ipa"
```

Or manually run **Combined native host · build only** with `host_mode=guest-prototype` on the desired branch. It has
read-only permissions and no publish job; automatic runs are path-filtered to combined-host inputs. It does not
require Apple-account/signing/TLS secrets. Its artifact is explicitly labelled
unvalidated. New combined artifacts are retained for **14 days**, and diagnostic
logs for **3 days**. The successful standalone unsigned native input is also
retained for 14 days, even if subsequent combined packaging fails; it is not a
combined-host artifact. All native build phases publish failure diagnostics. Existing uploads keep their previous expiry. The normal
release workflow remains unchanged.

Outputs (ignored by Git):

- `packages/VexSign+LiveContainer+SideStore.ipa`
- `packages/VexSign+LiveContainer+SideStore.integration-sources.tar.gz`
- `packages/VexSign+LiveContainer+SideStore.build.json`
- `packages/VexSign+LiveContainer+SideStore.checksums.txt`

The packager checks every cached asset's SHA-256 before executing/extracting it.
The SideStore asset ID, commit hashes and converter source digest are in
`inputs.lock.json`; no floating nightly URL is used. `dylibify` is compiled from
its pinned, SHA-256-checked source using the selected Xcode's macOS SDK, so the
converter matches the runner CPU rather than requiring a prebuilt tool binary. Deleted/replaced upstream assets cause a failure. Refresh locks only after
reviewing the matching source, binary hash, intent ABI and runtime compatibility.
The pinned source checkout is patched with `git apply --unidiff-zero --check` before building. Zero-context hunks avoid treating upstream whitespace-only context as new trailing whitespace.

## Guest-prototype installation / first run

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

## Upstream review and what “one install” actually means (2026-11-06)

The reviewed upstream [packaging script](https://github.com/LiveContainer/LiveContainer/blob/9108ae624ea001f7d7696d48407f890b48fa2653/.github/build_github.sh)
converts SideStore's executable to a loadable library, moves its app into
`Frameworks/SideStoreApp.framework`, adapts intents/widgets to SideStoreSupport,
and packages the result inside **one LiveContainer host IPA**. It does not install
an independent SideStore app behind the user's back. This prototype follows that
layout with pinned inputs rather than the script's floating nightly download.

There are two different installation inventories:

- **Device-installed:** an app registered with iOS/installd. This is what VexSign's
  Library device-installation badge queries. Signing an IPA is not evidence of it.
- **Container guest:** an app imported into LiveContainer's private app/data
  containers and launched by its runtime. A guest is not a separately installed
  iOS app; a Home Screen shortcut does not change that. Do not label a guest as
  device-installed or combine these inventories into a single misleading badge.

For a single-install **prototype** test, install the combined host IPA from the
manual workflow, not the ordinary versioned `VexSign-<version>.ipa`. SideStore and the bundled VexSign
are then opened inside the host; no separate SideStore or LiveContainer app
installation is needed. Initial host installation/re-signing, pairing, Apple
account setup and any signing/JIT prerequisites still apply. This does not bypass
Apple's provisioning limits or promise universal guest compatibility.

That packaging alone does **not** implement the accepted VexSign-primary design.
The remaining integration work is to put the container runtime/guest inventory
behind VexSign's primary UI, connect the native account/provisioning/renewal
pipeline, preserve data/account ownership across launches and upgrades, and pass
the architecture's native/device gates. Simply renaming the host or shipping a
second embedded account UI would not complete that work. The ordinary VexSign
release deliberately remains unchanged until those gates pass.

Before promoting any combined artifact, test on physical devices: clean install
with neither companion installed; first-run account/pairing setup; host↔VexSign↔
SideStore switching; guest import/launch and independent guest data; actual device
installation versus guest-only badges; expiration/renewal; cancellation/offline
recovery; and update/relaunch without data loss. Exercise supported signing/JIT
modes and document the tested iOS versions. Distribute the required corresponding
sources and retain upstream licenses/notices for the combined work.

### VexSign dual-mode install routing

Settings → Installation separates **App Routing** from **Direct Installation
Type**. Routing can be Automatic, Direct Paid / Certificate, or Containerized
Free Account. Automatic selects direct OTA/IDevice delivery when the selected or
app-associated identity has a readable, unexpired, non-revoked P12/profile pair
and either an enterprise profile or a profile lifetime over seven days. In a
loaded combined host, missing/incomplete/expired/revoked identities and short
profiles select the guest pipeline instead. Standalone builds retain their
existing direct pipeline for already signed or ad-hoc IPAs; this routing check
does not replace signing preflight, profile/device entitlement validation, or
PKCS#12 password verification.

The legacy installation preference values remain `0` (OTA), `1`
(pairing/IDevice), and `2` (embedded guest import). An existing value `2` stays
containerized in Automatic mode. Direct mode restores the last direct transport
when leaving that legacy state. Unsupported values fail explicitly rather than
silently choosing OTA. Explicit container mode requires the loaded process-local
runtime; merely installing a separate LiveContainer app does not activate it,
and no explicit mode silently falls back to the other pipeline.

Each installer snapshots its resolved route. Queue prewarming is invalidated if
that route changes, and batches containing any containerized item stop with an
explanation instead of mixing guest staging with device-install success.
Containerized Library, direct-URL and update flows may package an unsigned import
for the host's explicit import/sign step; the same unsigned bundle remains
blocked by direct-install signature verification for OTA/IDevice. Auto-import
still enqueues only when the existing install-after-signing preference requests
it. The Library Install action packages and validates the selected guest IPA, stages
it in the host inbox, then offers **Open container** or **Later**. The open action
requires no active VexSign tasks and explicit confirmation because the host
switch closes the current session. Finish import/signing in the host. Staging is
not installation: it does not set the device-installed badge, increment installed
analytics, offer a device-app Open button, or delete the library source. Guests
must be imported one at a time: other queued entries are skipped, and automatic
sign-and-install batches reject this route with an explanation rather than
reporting their guests as iOS installations.

For OTA, export/install the Root CA profile and enable Full Trust in iOS Settings;
VexSign cannot grant that trust itself. Pairing imports validate the plist before
atomically replacing the previous file, but only a real transport connection can
establish pairing validity/device trust/VPN connectivity. Recheck prerequisites
after setup or return to the app from Settings. The source implementation still
requires Xcode build/simulator tests and the physical-device acceptance described
above; portable checks are not a substitute for those tests.

### Independent container inventory

The combined runtime now exposes a read-only inventory query over the host's
local and app-group Applications directories. Library shows **Imported guest**
separately from **Installed** and the information sheet names both inventories.
The bridge returns only import state and version, never guest data, keychain
values or signing identities. Unavailable runtime, unreadable inventory, old
hosts without the selector and malformed replies do not become positive badges.
A guest's presence still does not prove it can sign, launch or renew.

The device probe and confirmation engine also reject evidence belonging to a
different bundle identifier. A container hook returning the host's proxy cannot
serve as confirmation that a requested guest was installed by iOS.

The combined build uses the shared Xcode selector, checks the host executable and
embedded framework Mach-O types, and emits checksums for the IPA, integration
sources and build metadata. Verify these before re-signing. The JSON explicitly
records physical-device acceptance as **not run**; an uploaded prototype is not a
production promotion or a supported VexSign-primary release.

Native-primary packaging retains LiveContainer's OpenSSL unchanged. VexSign's
copy is namespaced as `VexSignOpenSSL.framework`; only native-input Mach-O load
commands are rewritten and checked before signing. Unknown OpenSSL loader paths
and all other conflicting dependency/resource revisions remain hard failures.
This avoids assuming ABI compatibility; runtime/device acceptance is still needed.

The primary package keeps LiveContainer's `Settings.bundle` runtime preferences.
VexSign's root settings become a separate `VexSignNative` child pane, retaining
its acknowledgement panes and localisation files. Shared preference keys,
reserved child-pane names, unknown resource conflicts and symlink destinations
are rejected rather than silently replaced.

Compiled native/LC `Localizable.strings` and plural `.stringsdict` tables share
one main-bundle lookup space. Packaging unions disjoint keys (upstream LC keys
use the `lc.` prefix); identical shared values are retained, while any differing
shared value is rejected. Other resource collisions are not silently merged.
