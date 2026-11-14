# Application runtime models

What VexSign can do with application execution, what needs a differently built app, what needs
LiveContainer, and what no ordinary iOS app can do. Written from this repository's source and
from the LiveContainer source at the commit VexSign pins.

Nothing here was executed: no combined host was built, no guest was imported, and no device was
involved. Statements about LiveContainer come from reading its code, not from running it.

## The four execution models

| Model | What it is | Who can use it |
| --- | --- | --- |
| **A. Native VexSign** | The ordinary app: import, sign, install to a device, manage a library, talk to repositories. | Anyone with the ordinary IPA. |
| **B. Signed application** | The result VexSign produces. A signed IPA installs on a provisioned device via `installd`/OTA. Signing does **not** make an app runnable inside VexSign. | Devices covered by the profile. |
| **C. External execution environment** | LiveContainer, built as a combined host with VexSign inside it (`Integrations/EmbeddedContainer/build.py`). The guest runs inside the host process, not as an installed app. | Only the combined package, on a device that can install it. |
| **D. Restricted** | Launching arbitrary executables, JIT without an authorised mechanism, inventing entitlements, silent installation, unlimited free-account provisioning, indefinite background execution. | Nobody, through public APIs. |

The line that matters: **B does not imply C**. An IPA VexSign signed is a candidate for `installd`;
whether the container can run it is a separate question with its own constraints, answered by the
host's patching and signing steps.

## Capability matrix

Statuses: **native** = ordinary app; **signed** = needs a valid signature/profile; **container** =
needs the combined host; **restricted** = not implementable through public APIs.

| Capability | Model | Status | Notes |
| --- | --- | --- | --- |
| Import/inspect/sign an IPA | A | native | `FR+Import`, `SigningService` |
| Install a signed app on a device | A+B | signed | OTA, paired transport, or the container's guest import |
| Read installed inventory | A | native | Local LaunchServices probe; filtered lookups report unknown, never "not installed" |
| Uninstall from a device | — | *missing* | `DeviceConnectivity` reports it as a VexSign gap, not a platform one |
| Run an app inside VexSign's own process | — | restricted | Sandbox and code-signing boundaries; see below |
| Run a guest app inside a container | C | container | LiveContainer patches and re-signs the guest |
| Guest with app extensions | C | container | Not verified here; VexSign does not claim it either way |
| Guest that is 32-bit only | C | container | LC sets `classicMode` + `isJITNeeded` (`LCAppInfo.m`) |
| Guest that is encrypted | C | container | Refused by LC: "Please provide decrypted app" |
| Guest whose executable has no room for the tweak loader | C | container | LC records `LCTweakLoaderCantInject`; not statically detectable |
| JIT for a guest | C | container | Availability depends on the host's JIT setup and the device |
| Session switch between VexSign and the container | C | container | Restarts the host process; requires consent |
| Guest keychain isolation hooks | C | container | Guest prototype only; the native-primary layout keeps the host identity |
| Scheduled background work in a combined host | C | container | Native-primary only; the guest layout cannot register the host's handlers |
| Handoff to a *separately installed* container | — | restricted | Not a public API; a registered URL handler is not consent (see `EmbeddedContainerRuntime`) |

## LiveContainer interoperability findings

VexSign's integration with LiveContainer is **embedding, not cooperation**: the combined package
builds the upstream targets from a pinned commit (`Integrations/EmbeddedContainer/inputs.lock.json`,
`9108ae624ea001f7d7696d48407f890b48fa2653`) and reproduces the upstream packaging layout.

What that means for an external, independently installed LiveContainer:

- **No public import API.** VexSign's staging path goes through its own host entry point
  (`VEXEmbeddedRuntimeStageIPA`), which only exists inside the combined package. There is no
  documented IPC the ordinary app could use to hand an IPA to someone else's container.
- **No URL-scheme claim.** The code deliberately refuses to treat a registered handler as
  evidence: "A detected external URL handler is not enough" (`EmbeddedContainerRuntime`).
  Opening a scheme would at best launch another app; it would not stage, sign or import anything.
- **Shared files are not a contract.** Both apps can see some shared directories, but the
  layout, naming and permission expectations are LiveContainer-internal and version-specific, so
  writing into them would be an undocumented dependency on someone else's private format.
- **Identity collision is real.** The combined package carries `com.kdt.livecontainer`; it
  replaces or conflicts with a stock LiveContainer install rather than living beside it.

So the honest statement for the UI is what it already says: *the ordinary VexSign IPA cannot
import a guest into an external container* (`InstallPreflight`). The `.unsupportedByDesign`
verdict for `externalAppHandoff` in the new capability report encodes the same statement where a
test can enforce it.

What LiveContainer's source shows about the guest path — and therefore what VexSign cannot
promise before handing an IPA over:

1. It patches the executable in place (`LCPatchExecSlice`), including an arm64e slice fixup.
2. It refuses encrypted binaries outright.
3. It may be unable to inject its tweak loader (`PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER`) or
   find the expected segment layout (`PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH`). Neither is
   predictable without performing the patch, which happens inside the host.
4. It re-signs with its own certificate unless the existing signature validates.

Items 1, 2 and 4 are reasons VexSign reports the result as a *staged import*, never as an
installed or runnable app.

## What this pass implemented

`RuntimeCapabilityReport` (`App/iOS/VexSign/Backend/Companion/`) turns the three flags that used to be
read one at a time — `isGuestBuild`, `isPrimaryHost`, `VEXEmbeddedRuntimeAvailable()` — into one
table: environment plus every runtime operation with an honest reason when it is unavailable.

- `EmbeddedContainerRuntime.supportsScheduledGuestTasks` now reads the report, so the boolean and
  the matrix cannot disagree.
- `DiagnosticBundleExporter` writes `runtime.json` (environment and reason codes only — no paths,
  guest names or bundle identifiers) so a support bundle can say which execution layout the user
  was running without asking them.
- `externalAppHandoff` is `unsupportedByDesign` in every layout, and a test enforces that.

It adds no state, no second runtime manager and no new UI control. The confirmation text for a
session switch lives on the report (`sessionSwitchWarning`) but is not yet displayed by
`EmbeddedContainerControls`, which keeps its existing dialog.

## Apple platform restrictions

Stated as restrictions rather than worked around anywhere in this repository:

- An ordinary app cannot launch an arbitrary executable, and cannot execute another app's code
  inside its own process. Signing an IPA changes nothing about that.
- The sandbox still separates apps; shared containers exist only through documented, entitled
  mechanisms.
- JIT requires an authorised mechanism; the debugger-attached and JIT-less paths have different
  constraints, and a signed app cannot grant itself one.
- Entitlements must be authorised by a provisioning profile. VexSign reports uncovered
  entitlements as blocking instead of writing them anyway (`ProfileCompatibility`).
- Background execution is granted by iOS, not by the app.
- Installing an app is `installd`'s decision; an "installation" VexSign cannot observe is
  reported as `unconfirmed`, never as success.

Apple's documentation site was not reachable from the environment this was written in, so these
statements are grounded in this repository's implementation and the platform behaviour it
encodes, not in a freshly quoted page.

## Tests

`App/Tests/VexSignTests/RuntimeCapabilityReportTests.swift` — 9 tests, all pure: environment derivation for
each build shape (including both flags set), the ordinary app reaching nothing, external handoff
never available, native-primary versus guest-prototype matrices, hooks/host-tasks exclusivity, no
operation available without a loaded runtime, and the diagnostics export carrying only the two
documented value shapes.

**None of them has been executed** — no Swift toolchain exists in the authoring environment.

## Device testing still required

Everything in model C. The combined host has never been device-accepted (`Documentation/QA/DEVICE_TESTING.md`
holds the ladders, and `Integrations/EmbeddedContainer/README.md` says the same in its own words): guest import
of a small test IPA, a 32-bit guest, an encrypted guest (must be refused), a guest whose tweak
loader cannot be injected, session switching both ways, and a relaunch afterwards.

## Remaining limitations

- No uninstall path (model A gap, unchanged).
- No guest compatibility prediction: the failures LiveContainer reports at patch time cannot be
  reproduced by static inspection, so VexSign does not guess at them.
- `RuntimeCapabilityReport` is currently surfaced only in diagnostics; the settings screen still
  reads the flags directly for its buttons.
- Native-primary self-update, native archive handling and dyld compatibility remain unvalidated
  beyond the structural tests listed in `Integrations/EmbeddedContainer/README.md`.
