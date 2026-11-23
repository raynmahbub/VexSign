# VexSign — feature map against the reference projects

Status of every subsystem in your mapping, read from this repository's code, not
from the reference repositories' feature lists. (The original note named the agent
workspace branch it was checked out on; that branch is gone, so the source tree is
the reference.)

Legend: **Built** = code path exists end to end · **Partial** = core exists, a stated
piece is missing · **Adapted** = the capability exists but with a different, deliberately
safer mechanism than the reference · **Absent** = not in the tree.

---

## 1. The summary table

| # | Subsystem | Your primary references | VexSign status | Where it lives |
|---|---|---|---|---|
| 1 | Signing engine | Feather, KSign, ForgeSign, Zsign | **Built** | `Infrastructure/Signing/Engines/{Zsign,Cloud}`, `Execution/SigningPipeline.swift` |
| 2 | Certificate management | Feather, Odysseus, NexStore | **Built** | `Infrastructure/Identity/` (25 files) |
| 3 | Apple Account provisioning | SideStore, AltStore, Odysseus | **Built** | `Infrastructure/Accounts/`, `Packages/SideSign`, `Packages/NativeSigning` |
| 4 | Initial installation | AltLoad, Impactor, SideStore | **Built** (this app), **Absent** (self-bootstrap) | `Devices/Installation/` (34 files) |
| 5 | Device pairing | SideStore, Impactor, AltLoad | **Built** | `Devices/Transport/`, `Packages/DeviceBridge` |
| 6 | IPA management | Feather, RyukSign, NexStore | **Built** | `Archives/` (28 files), `Library` feature |
| 7 | Repository management | Feather, RyukSign, Zeus, NexStore | **Built** | `Infrastructure/Repositories/` (24 files), `Packages/AltSourceKit` |
| 8 | Batch signing | BatSign, KSign | **Built** | `Application/Signing/BatchSigningUseCase.swift`, `Tasks/BatchJobRunner.swift` |
| 9 | Background update workflows | BatSign, SideStore | **Partial** | `App/Lifecycle/AppDelegate+BackgroundTasks.swift`, `Tasks/EcosystemMaintenance.swift` |
| 10 | Guest application containers | LiveContainer | **Adapted** | `Platform/Compatibility/EmbeddedContainerRuntime.swift` |
| 11 | OTA installation | ForgeSign, Feather | **Built** | `Devices/Installation/OTA/`, `OTAExporter.swift` |
| 12 | Certificate status API | FlareStore API | **Adapted** (on-device OCSP, no third-party API) | `Identity/CertificateInspector.swift`, `CertificateStatusManager.swift` |
| 13 | Automated builds | BatSign, ForgeSign | **Absent** (by design) | — |

Nine of thirteen are built outright. Three are built but not the way the reference does
them, and each of those is a decision I would defend rather than a gap to close.

---

## 2. Subsystem by subsystem, with the evidence

### 1. Signing engine — Built

`Infrastructure/Signing` is 59 files / ~12,600 lines in five stages:
`Planning` → `Transformation` → `Execution` → `Verification`, with the engine itself
under `Engines`.

- **Zsign** is vendored and pinned, not reimplemented:
  `Packages/Vendor/Zsign` at `6ffe703` (MIT AND Apache-2.0, recorded in
  `Vendor/manifest.json`), driven by `Engines/Zsign/ZsignEngine.swift` +
  `ZsignAdapter.swift`.
- A second engine exists for the paid path: `Engines/Cloud` (`CloudSigningClient`).
- Signing is not a single `zsign` call. `Execution/SigningPipeline.swift` owns the
  sequence; `Verification/` re-checks the *output* (`SignatureVerifier`, `BundleSignature`,
  `NestedBundleAudit`, `BundleExecutableAudit`, `SignerMatch`); `Planning/PreflightChecks`
  refuses a configuration before anything is written.
- Tweak injection (`Transformation/TweakExtractor`, `TweakManager`, `TweakCompatibility`)
  and entitlement work (`EntitlementsManager`, `EntitlementBuilder`) live here, which is
  why they are not separate features in the UI.

This is the strongest part of VexSign and the part where "study Feather, KSign, ForgeSign"
has already paid off: the value taken from those projects is the *sequence* — preflight,
inject, sign, verify, then install — not their code.

### 2. Certificate management — Built

`Infrastructure/Identity` holds import, inspection, expiry, revocation state, export,
removal and a batch checker:

- Import: `CertificateManagementService` + `Certificates/CertificateImportBundle`
  (`.p12`, profile, folder or `.zip` holding all three — added this week because the old
  screen could not accept how certificates are actually distributed).
- Authentication, not text parsing: `Certificates/ProvisioningProfileParser` admits a
  profile only after `VexVerifyProvisioningProfileCMS` consumes the whole CMS envelope,
  pins the three Apple roots and requires exactly one Apple-issued signer. A profile that
  fails this is reported as untrusted, not silently accepted.
- `SignatureVerifier`-grade pairing: the `.p12` leaf is compared by fingerprint against
  the certificates the profile names, so a mismatched pair is refused at import instead of
  failing at install time.
- Lifecycle: `CertificateExpiryMonitor`, `CertificateStatusManager`,
  `CertificateRemoval`, `CertificateInspector`, `BatchCertChecker`.

**Difference from the references:** Feather and NexStore happily accept a profile and
show whatever metadata it claims. VexSign refuses an unauthenticated CMS envelope. That
is narrower on purpose — the whole point of importing a certificate is that its identity
is known.

### 3. Apple Account provisioning — Built

This is the SideStore/AltStore problem (free Apple ID → development certificate →
provisioning profile) and it is solved with two packages plus a coordinator:

- `Packages/SideSign` — GrandSlam authentication, SRP-6a, developer-portal calls,
  CMS/PKCS#7 signing, streaming ZIP. (The same protocol family SideStore uses; it is
  carried as an in-repo SwiftPM package so the app builds from a clean clone.)
- `Packages/NativeSigning` — the app's own pure-Swift implementation of the Apple
  identity path: `Authentication/`, `Provisioning/NativeAppleProfileCMSVerifier`,
  `Identity/`, `Security/`, with `PythonTests/` for the parts that can be tested off-device.
- `Infrastructure/Accounts/` — `NativeSigningManager` (full auth lifecycle, 2FA challenge
  stream, renewal, inventory), `AnisetteProvider`, `SigningModeManager`.
- UI: `Presentation/Features/Accounts`.

**Honest boundary:** authentication and certificate/profile issuance are implemented, and the
flow ends by *importing* what it obtained: `NativeSigningManager.exportToCertificateStore` writes
the account's `.p12` and profile into the ordinary certificate store as a `CertificatePair`, which
the imported-certificate engine then signs with. Two things are therefore separate, and used to be
reported as one:

| Question | Answer | Evidence |
| --- | --- | --- |
| Can an account's certificate be used to sign here? | Yes, through the certificate store | `AppleAccountWorkspaceAdapter.importCertificate` → `exportToCertificateStore`; `Renewability.importedPair` |
| Does this build sign *inside* the account engine? | No — `notIntegrated` | `SigningMethodCapabilities.nativeAppleAccountSigning`, enforced by `check-native-handoff.py` until `Documentation/DeviceTesting/evidence/native-signing-promotion.json` exists |

Whether a given account can *complete* a device install is a policy question decided by Apple, not
by VexSign, and the app reports that instead of pretending success.

### 4. Initial installation — Built for other apps, Absent for itself

Two delivery pipelines coexist behind `SigningModeManager`:

- **directPaid** — certificate-signed IPA → device, via `DirectInstaller`,
  `AppInstaller`, `InstallQueue`, `InstallPreflight`, `InstalledAppProbe`, TLS loopback
  (`Devices/Installation/TLS`), OTA (`Devices/Installation/OTA`).
- **containerized** — stage a guest for an embedded host (see #10).

Both are guarded: `InstallEvidenceSummary` distinguishes "the device confirmed it" from
"we did not get an answer", and an unconfirmed install demands a separate device check
before it can be retried — that is what stops an install loop from hammering a device.

**What is absent:** VexSign cannot install *itself* onto a device with no developer
account. AltLoad/Impactor solve that with a computer-assisted first boot; there is no
self-bootstrap path in this tree. If you want a computer-free first install, that is a
genuine new subsystem, not a refactor of what is here.

### 5. Device pairing — Built

`Devices/Transport`: `LockdownClient`, `PairingBridge`, `CompanionClient`,
`CompanionSecretStore`, `DeviceBootstrapModel`, plus `Packages/DeviceBridge` (pinned
vendored native iDevice sources with `inputs.lock.json` and their own LICENSE) and
`Infrastructure/Identity/PairingRecordDocument` for bounded, format-aware pairing-file
inspection. A pairing record is parsed, never trusted on sight.

### 6. IPA management — Built

- `Archives/Extraction/IPAExtractor` — streaming extract with per-entry containment
  revalidation, CRC check, size check, deadline, and a cancellation checkpoint.
  `Security/Archives/ArchiveSafetyValidator` rejects absolute paths, traversal, symlinks,
  duplicates, path-type conflicts and compression bombs before anything is written.
- `Archives/IPA/` — `IPAWorkspace`, `AppFileHandler`, `PackageImportService`,
  `IPAFileEntry`, `IPAChangeJournal`, `IPAExportNaming`.
- `Presentation/Features/{Library,Files,Import,Downloads}` — explorer, export, duplicate
  review, staged downloads.

**Changed this week:** import now finds the app bundle rather than requiring `Payload/`,
decides the container from its bytes rather than its extension, and accepts a `.zip`
package. Previously a repacked app failed *after* a full extraction.

### 7. Repository management — Built

`Infrastructure/Repositories` is 24 files: `SourceFeedLoader`, `SourceCatalogStore`,
`RepositorySyncEngine`, `RepositoryImporter`/`Exporter`, `RepositorySnapshotCache`,
`SourceProvenance`, `SourceRemoval`, `LinkTagParser`, `TelegramLinkParser`,
`AppStoreTracker`, `GitHubIPAReleases`/`GitHubReleaseSource`, `PremiumFilterPreferences`.
`Packages/AltSourceKit` supplies the source schema. UI: `Features/Repositories`.

The design point worth keeping: a source's URL is validated by `SourceURLPolicy`, and
every feed keeps provenance, so a downloaded binary can be traced to the source revision
that advertised it.

### 8. Batch signing — Built

`Domain/Entities/BatchSigning.swift` (mode + request), `Application/Signing/
BatchSigningUseCase.swift`, `Infrastructure/Tasks/BatchJobRunner.swift`,
`BatchSigningAdapter.swift`, and `Features/Library/Views/Batch/` (`BatchSignView`,
`BatchProgressView`). It runs through the same `SigningPipeline` as a single app, so a
batch cannot sign differently from a single run.

### 9. Background update workflows — Partial

`App/Lifecycle/AppDelegate+BackgroundTasks.swift` registers
`com.vexsign.background.maintenance`, `.download` and `.download.continued`;
`Tasks/EcosystemMaintenance` schedules `com.vexsign.ecosystem.refresh` every ≥6 h to
refresh repositories and certificate status. `Infrastructure/Updates` (7 files) has
`AppUpdateChecker`, `UpdateAllManager`, `PerAppUpdateRules`, `SkippedUpdatesManager`,
`SelfUpdateManager`.

**Why partial, and why that is correct:** iOS grants `BGAppRefreshTask` at the system's
discretion and never guarantees a wake-up. SideStore works around this with a
notification/keep-alive arrangement and a 7-day signing window. VexSign schedules the
work and reports it honestly; it does not claim a refresh happened. Automatic *re-signing*
before profile expiry is therefore a best-effort sweep, not a guarantee — saying otherwise
would be the same class of lie as the old "check your password" import error.

### 10. Guest application containers — Adapted

`Platform/Compatibility/EmbeddedContainerRuntime.swift` recognises
`Destination.container` / `.sideStore`, reports `isGuestBuild` / `isPrimaryHost`, exposes a
`RuntimeCapabilityReport`, tracks guest state, and explicitly declines to register
scheduled BG tasks in a guest process (`supportsScheduledGuestTasks`) because a guest's
task handlers would not be installed in the host.

This is the LiveContainer idea — run guest apps inside a host that owns the signing
identity — reached by *interoperating* with such a host rather than by embedding
LiveContainer's loader/containment machinery. Embedding it would mean adopting its
patching model and its security assumptions wholesale; given the requirement that VexSign
stay one coherent app with independent modules, the boundary is the right call.

### 11. OTA installation — Built

`Devices/Installation/OTA/` (`ManifestService`, `ServerInstaller+Compute`), `OTAExporter`,
`Features/Installation/Views/OTAView.swift`, with TLS identity generation in
`Devices/Installation/TLS` (`LocalTLSIdentity`). The manifest is generated and signed
locally; itms-services never sees a certificate password.

### 12. Certificate status API — Adapted

FlareStore is closed-source with a documented API; VexSign does **not** call it. Instead
`Identity/CertificateInspector.inspect(online: true)` runs `SecPolicyCreateRevocation`
with `kSecRevocationOCSPMethod | kSecRevocationRequirePositiveResponse` against Apple's
OCSP responder, using certificate identifiers only, and caches a verdict word, a sentence
and a date (`CertificateStatusManager`, persisted under
`VexSign.certificate.revocationSnapshots`).

**Why this is better than the reference path:** a third-party status API sees which
certificates you hold. On-device OCSP asks Apple directly, and no private key or password
ever leaves the device. The same reasoning is why there is no telemetry endpoint.

Related but different: `Identity/NexCerts.swift` fetches a *community certificate
catalogue* from `sideloading.net` (a fixed host asserted by a test, 16 MB download cap,
single audited URL builder). That is a convenience for trying the signing flow, and it is
labelled as such in the UI — not a status service.

### 13. Automated builds — Absent, deliberately

BatSign and ForgeSign offer CI-style build+sign pipelines. VexSign has no in-app
build server: taking a user's certificate and Apple credentials into a background build
queue is a security decision with no user-visible benefit over signing locally. If you
want scheduled *signing* of an existing IPA, that is `BatchSigning` + `EcosystemMaintenance`
and it can be wired without new trust boundaries.

---

## 3. How the pieces actually connect

```
 Import (IPA/TIPA/ZIP)              Certificate (p12 + profile, or one .zip)
        │                                        │
 ArchiveSafetyValidator                  ProvisioningProfileParser
        │  (paths, symlinks, bombs)              │  (CMS, Apple pins, expiry)
 IPAExtractor ──────► IPAWorkspace               │
        │                                        ▼
        ▼                              SigningIdentity (fingerprint match)
 Library / Files ──► SigningPipeline ◄───────────┘
                        │ Planning  (PreflightChecks, Options, entitlements)
                        │ Transform (tweaks, extension policy)
                        │ Execute   (ZsignEngine | CloudSigningClient)
                        │ Verify    (SignatureVerifier, NestedBundleAudit)
                        ▼
              ┌─────────┴──────────┐
        directPaid            containerized
      InstallQueue / OTA     EmbeddedContainerRuntime
              │                    │
        AppInstaller ──► device    guest stage ──► host imports
              │
      InstallEvidenceSummary (confirmed vs unknown)
```

Every arrow is a protocol declared in `Domain/Protocols` and implemented in
`Infrastructure/*Adapter`, wired in `App/Composition/AppContainer.swift`. That is the
concrete meaning of "one coherent application with independent modules": the Presentation
layer never imports an infrastructure type, and a Python gate
(`Tools/Validation/architecture-rules/test_architecture_boundaries.py`, 7 tests) fails the
build if it does.

---

## 4. What "properly implemented" means here, and what I will not do

Three things I would flag before any copying from the references:

1. **Do not import their Swift.** Feather, KSign, RyukSign, BatSign and KorSign are
   forks of each other with divergent local patches; the same class appears three ways
   across them. What transfers is the workflow, not the file.
2. **Licences differ per project** and several are unlicensed or "all rights reserved"
   despite being public. VexSign already records each vendored dependency's upstream
   commit and licence in `Packages/Vendor/manifest.json`; that is the bar for anything new.
3. **The security boundaries are the product.** Profile CMS verification, path
   containment, pairing-file parsing and install-evidence rules are the parts that make
   the app safe to point at an untrusted IPA. None of them should be relaxed to match a
   reference behaviour.

Two honest gaps remain, both scoped as new subsystems rather than missing wiring:

- **Self-bootstrap** (install VexSign with no developer account) — AltLoad/Impactor
  territory; nothing in the tree does it.
- **Guaranteed refresh** — iOS will not promise a background wake-up; the app schedules
  and reports, it does not guarantee.

Everything else in your mapping is implemented, and nine of the thirteen subsystems are
built end to end today.
