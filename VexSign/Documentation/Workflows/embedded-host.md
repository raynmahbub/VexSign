# Embedded host: LiveContainer and SideStore inside VexSign

> **Experimental.** Neither build mode is device-accepted, and an ordinary install has no
> embedded runtime at all. This page is the reading path; the authoritative packaging rules
> are in [Integrations/README.md](../../Integrations/README.md).

The embedded host is a **different build of the app**, not a feature an ordinary install can
switch on. `VexSign/Integrations/build.py` produces a combined package that embeds the upstream
LiveContainer runtime and SideStore; the IPA from `make` does not. Everything below is about
what that means in the app, in diagnostics, and for a reviewer.

## 1. Which build am I running

`EmbeddedContainerRuntime` (`Platform/Compatibility/EmbeddedContainerRuntime.swift`) reads three
facts and nothing else, and `RuntimeCapabilityReport`
(`Platform/Compatibility/RuntimeCapabilityReport.swift`) is the one place that turns them into
answers:

| Fact | Where it comes from | What it means |
| --- | --- | --- |
| `isGuestBuild` | `VexSignEmbeddedGuest` in the app's Info.plist | The combined package, running VexSign as a guest of the host. |
| `isPrimaryHost` | `VexSignPrimaryHost` in the app's Info.plist | The native-primary layout: VexSign owns the entry point, the runtime is a tenant. |
| `runtimeLoaded` | `VEXEmbeddedRuntimeAvailable()`, resolved when the runtime dylib is present | This process can reach the host entry point. |

Those three values map to an `Environment` — `standalone`, `combinedNativePrimary`,
`combinedGuestPrototype`, or `combinedUnidentified` when the flags are missing or contradictory —
and to a per-operation `Availability`. The two layouts differ deliberately:

- **Guest prototype** replaces the entry point, so it can install guest keychain hooks and
  switch sessions, and it cannot register this app's background tasks.
- **Native primary** keeps the host application identity, so it has no guest keychain hooks, and
  its background tasks belong to VexSign itself.
- **Standalone** reaches nothing that needs the host. Background tasks still run: they belong to
  this app and are gated on the layout, not on the runtime.

`externalAppHandoff` is unavailable in every layout, by design: a detected URL handler is not
evidence that a separately installed container would accept an import.

## 2. What the user sees

Because the runtime is a build property, the app must not present the controls as broken. Each
`Reason` carries an `explanation` — `runtimeNotLoaded`, `notPartOfThisLayout`,
`unsupportedByDesign` — and `EmbeddedRuntimeAvailabilityNote` renders it wherever the feature is
missing:

- Home shows the "Built-in apps" card with the explanation instead of omitting it.
- Installation shows the note in place of two unlabelled GitHub links.
- The companion screen shows it for any layout that cannot reach the host, not only the guest
  build.

Signing and installation are unaffected by all of this: they use the certificate, provisioning
profile and transport the user configured, and they work in every build.

## 3. Importing a prepared IPA into the container

The handoff is deliberately narrow, because a container import is not an installation:

1. `EmbeddedContainerRuntime.stageIPA` copies the file into VexSign's own Caches (LiveContainer
   symlinks guest `tmp` to the host's, so a staged file must be owned by the guest before the
   native home-containment check), validates it with `ArchiveSafetyValidator`, and cancels
   between steps if the task is cancelled.
2. The native call copies it into the host's inbox synchronously and commits
   `VexSignPendingImport`. After that point only the host may discard it.
3. The host imports it. A successful handoff proves none of: Apple-authorised signing, a
   successful launch, or renewal.

`ContainerGuestState` keeps that honest: `unavailable` (no runtime), `unknown` (the host was
asked and did not answer), `notImported`, and `imported(version:)` are separate states, and only
the last one claims the file arrived.

## 4. Building and validating one

```sh
make VexSign
APP_VERSION="$(grep -m1 -oE 'MARKETING_VERSION = [^;]+' VexSign.xcodeproj/project.pbxproj | awk '{print $3}')"
python3 VexSign/Integrations/build.py --mode native-primary --vexsign-ipa "packages/VexSign-${APP_VERSION}.ipa"
```

`embedded-container.yml` runs that packaging for a path-filtered change, uploads labelled
artifacts and never publishes them. Start it from **Actions → Combined host → Run workflow** and
choose `host_mode`. Structural and mock tests are not device acceptance: archive contents, dyld
resolution, Apple-authorised signing and cross-session delivery remain unverified until someone
runs them on hardware. See [device-testing.md](device-testing.md).

## 5. Reviewing a change here

- New capability? Add an `Operation` and a `Reason` in `RuntimeCapabilityReport`, with a test in
  `VexSignTests` for each environment row, rather than reading a boolean at the call site.
- New screen that is only meaningful with the runtime? Render
  `EmbeddedRuntimeAvailabilityNote` in its place when unavailable, so the section explains
  itself instead of disappearing.
- Anything user-visible about import or execution must keep the distinction between "the host
  accepted the file" and "the app runs".
- Diagnostics export the report as `environment` plus `unavailable:<reason>` per operation —
  redaction-safe by construction: no paths, bundle identifiers or guest names.

## Related

- [Integrations/README.md](../../Integrations/README.md) — packaging modes and their limits.
- [COMPANION_SIGNING.md](COMPANION_SIGNING.md) — the companion/handoff path.
- [security.md](security.md) — the trust boundaries this page relies on.
- [bootstrap.md](bootstrap.md) — why the first installation is separate.
