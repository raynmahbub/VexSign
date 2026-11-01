# Reference-project comparison

Companion to [`AUDIT_2026-10-31.md`](AUDIT_2026-10-31.md) and [`ROADMAP.md`](ROADMAP.md).

Every project below was cloned on 2026-10-31 at its default-branch tip and inspected as source —
not from its README. Repository identity, licence, star count and last-push date come from the
GitHub API on the same date. Where a project named in the brief could not be identified with
confidence, that is stated rather than guessed.

The question this document answers is narrow: **for each project, what is there that VexSign
should have, and how may it legally and technically be obtained?**

---

## 1. Identity verification

| Brief name | Resolved repository | Licence | ★ | Last push | Relationship |
| --- | --- | --- | ---: | --- | --- |
| Feather | [`claration/Feather`](https://github.com/claration/Feather) | GPL-3.0 | 4,972 | 2026-10-06 | VexSign's upstream base |
| FeatherPlus | [`TomerGamerTV/FeatherPlus`](https://github.com/TomerGamerTV/FeatherPlus) | GPL-3.0 | 17 | 2026-08-13 | Feather fork (backup-centric) |
| KSign | [`Nyasami/Ksign`](https://github.com/Nyasami/Ksign) | GPL-3.0 | 724 | 2026-10-22 | Feather fork, ESign-style |
| RyukSign | [`faroukbmiled/RyukSign`](https://github.com/faroukbmiled/RyukSign) | GPL-3.0 | 110 | 2026-09-10 | Feather fork |
| KorSign | [`korboybeats/KorSign`](https://github.com/korboybeats/KorSign) | GPL-3.0 | 2 | 2026-10-13 | RyukSign fork — **low-confidence identity**, see §8 |
| MySignReincarnated | [`gliddd4/MySignReincarnated`](https://github.com/gliddd4/MySignReincarnated) | GPL-3.0 | 1 | 2026-09-13 | RyukSign fork |
| NexStore | [`NexSideloading/NexStore`](https://github.com/NexSideloading/NexStore) | GPL-3.0 | 28 | 2026-10-31 | Feather fork |
| Odysseus | [`mirazbakis/Odysseus`](https://github.com/mirazbakis/Odysseus) | GPL-3.0 | 38 | 2026-10-07 | Feather + FreeSign fork |
| SideStore | [`SideStore/SideStore`](https://github.com/SideStore/SideStore) | **AGPL-3.0** | 7,180 | 2026-10-27 | AltStore fork (`develop`) |
| LiveContainer | [`LiveContainer/LiveContainer`](https://github.com/LiveContainer/LiveContainer) | **AGPL-3.0** | 13,634 | 2026-10-17 | Independent |
| AltStore / AltServer | [`AltStoreIO/AltStore`](https://github.com/AltStoreIO/AltStore) | **AGPL-3.0** | 14,816 | 2026-10-21 | Independent |
| Zsign | [`zhlynn/zsign`](https://github.com/zhlynn/zsign) | MIT | 1,940 | 2026-10-20 | Signing engine |
| — (engine package) | [`claration/Zsign-Package`](https://github.com/claration/Zsign-Package) | MIT | — | pinned `6ffe703` (2025-07-27) | VexSign submodule |
| TrollStore | [`opa334/TrollStore`](https://github.com/opa334/TrollStore) | MIT (one BSD-4 file) | 22,489 | 2026-04-01 | Independent |
| AltSourceKit | **no standalone upstream** (`claration/AltSourceKit` → 404) | GPL-3.0 (as part of Feather) | — | — | Vendored in Feather **and** in VexSign |

**AltSourceKit finding.** The brief lists AltSourceKit as an external reference. It is not a
separate project: it is a SwiftPM package inside the Feather repository (same 8 files in Feather,
every fork and VexSign). VexSign's copy is the only diverged one — `ASRepository.swift` is 766
lines there versus 683–698 in every fork inspected, i.e. VexSign already carries the newest
schema handling in the family. There is nothing to import; VexSign's copy **is** the reference.
Its `ASDecrypt`/`EsignSourceKey` pieces bundle third-party ESign decryption keys, which is worth a
licence/ethics note (VX-25) rather than a feature.

### 1.1 Licence boundary (read before any code decision)

VexSign is **GPL-3.0**. That splits the references into two groups:

- **GPL-3.0 (Feather family).** Feather, FeatherPlus, Ksign, RyukSign, KorSign, MySign,
  NexStore, Odysseus. Code may be adapted into VexSign under the same licence, provided the
  attribution and the licence notices travel with it. VexSign's own `upstream-merge-kit` workflow
  already records upstream repo/commit/author in commit trailers, which is the right mechanism.
- **AGPL-3.0.** SideStore, LiveContainer, AltStore, and — critically — **SideSign**, which
  Odysseus vendors and which is the library that performs Apple ID authentication and
  certificate creation. Linking AGPL code into VexSign would require relicensing the whole
  distributed application as AGPL. **No AGPL code may enter VexSign.** Ideas, behaviours and
  design patterns may be re-implemented independently; that is what this document recommends.
- **MIT.** zsign, idevice, TrollStore (mostly). Compatible, but TrollStore's technique is not
  applicable (see §7).

---

## 2. Feather — the upstream baseline

**What it is.** 97 Swift files / 11,009 lines: tab shell, certificate import, Zsign signing,
AltStore sources, downloads, Live Activities, WebDAV manager, widgets. VexSign forked it and is
now roughly 5.8× its size.

**What upstream has that VexSign does not, by file:**

| Upstream file | VexSign equivalent | Verdict |
| --- | --- | --- |
| `BackgroundAudioManager.swift` (AVAudioEngine silent playback) | `BackgroundTaskManager` (refcounted `AVAudioSession` + `BGTask` + expiry notifications) | VexSign's is stronger; adopt nothing |
| `InstallPreviewView.swift` | `DirectInstallSheet`, `InstallProgressView`, `InstallCardView` | covered |
| `ArchiveView.swift` | File Manager + archive browser + IPA Explorer | covered |
| `Storage+SourceMetadata.swift` | `Storage+Sources`, source health, snapshot cache | covered |
| `UpdateManager.swift` | `SelfUpdateManager` + `AppUpdateChecker` + `UpdateAllManager` | covered and extended |
| `FeatherApp.swift` | `VexSignApp.swift` | covered |

**Verdict: reference only.** Upstream is useful for two things: (a) a regression source if a
VexSign-specific bug is suspected in shared code, (b) a reminder of the original contract when
refactoring storage/signing. The repo already has an `upstream-radar` workflow for exactly this.

**One caution.** Feather and most forks pass `removeProvision: !_options.removeProvisioning`
into the Zsign wrapper. That looks wrong but is *correct* for the pinned engine (see audit §3.3).
Any engine bump changes the polarity of that argument.

---

## 3. FeatherPlus — backup/restore fork

**What it is.** 98 files, a Feather fork advertising backup/restore between installs through the
Documents app. Inspected: it has no dedicated backup module — the mechanism is Files-app
exposure of the app container (`FileManager+documents`, `URL+toSharedDocuments`).

**VexSign state.** `BackupManager` + `BackupCrypto` produce a single encrypted `.vexbackup`
container with AES-GCM + PBKDF2-200k, selectable components (certificates/sources/settings/tweaks)
and a restore summary. That is strictly more capable — but it currently permits an *unencrypted*
container holding private keys (audit AX-09 / VX-11).

**Verdict: reference only.** Nothing to adopt. The lesson is the opposite one: a visible
Files-app escape hatch is useful for users, and VexSign already exposes "move to shared
documents" paths; keep the encrypted backup as the supported transfer path.

---

## 4. Ksign — the ESign-style fork

**What it is.** 136 Swift files, ★724, the most actively maintained non-VexSign fork
(pushed 2026-10-22). ESign-flavoured UX built on the Feather base.

**Distinctive code, verified:**

- `BulkSigningView.swift` — per-app `AppSignConfig { app, options, icon }` array, one certificate
  for the batch, per-app editing before start. VexSign's `BatchSignView` +
  `BatchAppOptionsView` + `BatchJobRunner` cover the same ground.
- `ExtractionService.swift` — archive extraction with a progress callback, dispatching to
  `ArArchiveKit`, `SWCompression`, `ZIPFoundation`, `Zip`. VexSign has `ArchiveEngine`,
  `Decompression`, `AR.swift`, with an explicit safety validator in front.
- `CertificateService.swift` — a dedicated certificate-import service with typed errors. VexSign
  has `CertificateFileHandler` + `CertificateReader` + `FR.checkPasswordForCertificate`.
- `LogsManager`/`LogsModel`, `HexEditorView`, `PlistEditorView`, `FilesViewModel` — all covered by
  VexSign's `SigningLog`/`LogsView`/`LogPresentation`, IPA Explorer hex/plist editors and File
  Manager.

**Verdict: reference only.** Nothing here exceeds VexSign's implementation. Its extraction path
is, if anything, weaker: no pre-extraction archive validation comparable to
`ArchiveSafetyValidator`.

---

## 5. RyukSign, KorSign, MySignReincarnated — the fork cluster

These three share one lineage (RyukSign → KorSign, RyukSign → MySign) and 215–236 files each.
VexSign already contains most of their additions (tweak manager, file-transfer server, enhanced
download manager, widget, news, source cache, update rules). The comparison therefore focuses on
the deltas that are genuinely better.

### 5.1 KorSign — the single most valuable reference in the family

`KorSign/.../InstalledAppProbe.swift` and `OTAInstallState.swift` (verified source) solve the
problem VexSign gets wrong (audit AX-05):

- **Real installed-state evidence** through LaunchServices:
  `LSApplicationProxy.applicationProxyForIdentifier:` → `isInstalled`, `isPlaceholder`,
  `shortVersionString`, `bundleVersion`, `bundleURL`, `registeredDate`; scalar BOOL returns are
  read through a correctly-typed `@convention(c)` function pointer (their comment explains why
  `perform(_:)` cannot be used for BOOL).
- **Install progress with meaning**: `LSApplicationWorkspace.installProgressForBundleID:makeSynchronous:`
  → `Progress`, then `installPhase`, `installState`, `ls_expectedFinalInstallPhase`, and
  `NSStringFromLSInstallState:` for a name.
- **A defensible state machine** (`OTAInstallState`): explicit phases (idle/waiting/downloading/
  verifying/finished), per-phase deadlines (120 s waiting, 600 s downloading/verifying), a rule
  that "progress ended" retires the UI but does not authorise deletion, and confirmation only when
  state is `Finished` **and** the phase equals the expected final phase (installing or restoring
  app data) — never a placeholder or download.
- Their comment states the OTA-specific truth VexSign ignores: *"OTA has no cancellation callback.
  Timeouts are failures, never user cancellations."*

Also present: `InstallationArchive`, `ArchivePreparationGate`, `UploadWorkspace`,
`TemporaryExport`, `LibraryPersistence`, `InstalledAppProbe`, `CertificateSelection`,
`PrimaryTabEmptyState`.

**Adopt (model, GPL-compatible, with attribution):** the confirmation state machine and the probe
adapter. Not the files verbatim — VexSign's installer has a different architecture
(`AppInstaller` + `InstallQueue` + `InstallCardView`), and Bolting KorSign's view-layer
assumptions onto it would create exactly the duplication this project must avoid. Implement
`InstallConfirmation` as pure logic with tests (VX-05).

**Do not adopt:** KorSign's Zsign call passes `removeProvision: _options.removeProvisioning`
without the negation; against the pinned engine that embeds the profile when the user asked to
remove it. This is the clearest example of why cross-fork copying needs verification.

### 5.2 MySignReincarnated — UX consolidation

Distinctive: `DefaultTweaksView` (one screen listing every injectable tweak with a
"inject by default" toggle and bulk selection), `SourceCache`/`SourceCacheSettings`,
`DownloadHistory`/`DownloadHistoryView`, `NewsFeed`/`NewsFeedView`, `RepositoryIconStore`,
`HoldToConfirm`, `IconTintCache`, `ImagePagerView`.

VexSign already has the *model* (`TweakModels.swift:222-274`: `injectByDefault`,
`autoInjectBundleIds`, `resolveAutoInject(forBundleId:)`), the offline snapshot cache, the unified
task ledger, source news and the Nuke-backed image pipeline. The genuine gap is presentation:
there is no single "which tweaks do I always want?" screen.

**Adopt:** the consolidated default-tweaks screen as a small UI task (VX-23). **Reject:**
duplicating caches/history — VexSign's existing services own that state.

### 5.3 RyukSign — closest layout, no unique capability

215 files; tweak manager, file-transfer server, enhanced downloads, widget. All present in
VexSign. Useful as a behavioural cross-check for the tweak-injection UX; nothing to adopt.

---

## 6. NexStore — "patching and tweak injection"

**What it is.** 99 Swift files, ★28, pushed on the audit date. A small Feather fork.

**Verified claim check.** The brief describes NexStore as an app-patching/tweak-injection
reference. Its source does not contain a patching engine: `TweakHandler.swift`, `ZsignHandler.swift`
and `SigningHandler.swift` are Feather's (with the same light edits as the other forks). There is
no binary-patch pipeline beyond Zsign dylib injection, no Asset.car compiler, no code-injection
framework. Its one structurally new UI is `MoreView.swift`.

**What VexSign actually took from it.** `NexCerts.swift` and `OfficialCertificatesView.swift`
carry the header *"Free certificate catalog imported from NexStore (NovaDev404)"* and download
third-party p12 + profile + password from `sideloading.net`. That is the single highest-risk
inheritance in the codebase (audit AX-04 / VX-04) and is labelled "Official" in the UI.

**Verdict:** no capability to adopt; one liability to contain. NexStore should not be treated as
an engineering reference for patching.

---

## 7. Odysseus — certificate provisioning and signed OCSP

**What it is.** `mirazbakis/Odysseus`, GPL-3.0, ★38, pushed 2026-10-07: "an advanced Feather and
FreeSign fork". 112 Feather files plus a vendored **SideSign** package and dedicated
`Feather/Backend/{AppleID,Certificates}/` modules.

**Genuinely new capabilities (verified in source):**

1. **On-device certificate provisioning from an Apple ID.** `Backend/AppleID/ODAppleIDManager.swift`
   plus SideSign: GrandSlam/SRP authentication (`GSACryptoKit`), Anisette data
   (`AnisetteKit`), developer-portal APIs for teams, devices, App IDs, certificates and profiles,
   local PKCS#12 creation/export, CodeSignKit for CMS signing, libdeflate for streaming zip
   (`SideSign/Sources/...`). Users get a 7-day development profile without owning a p12.
2. **Signed OCSP verification.** `ODDER.swift` (a DER writer/parser), `ODOCSPCore.swift`
   (RFC 6960 request/response, `tbsResponseData` retained for signature checks), `ODX509.swift`,
   `ODOCSPChecker.swift`, `ODCertificateStatusStore.swift` (status per certificate, notifications,
   re-check policy). Their README states the responder's signature is checked and that states are
   Valid / Revoked (date+reason) / Unknown / Couldn't check — the same honesty VexSign's
   `CertificateInspector` documents.
3. **Sign pipeline** (`ODSignPipeline.swift`) with revocation policy (warn / block / allow).

**Licence reality.** Odysseus is GPL-3.0, but **SideSign is AGPL-3.0** (its `Package.swift` says
so explicitly: *"Vendored from SideStore/Catalyst … AGPL-3.0"*). The Apple ID provisioning
capability therefore **cannot** be brought into VexSign by code reuse. It would also import a
credential-handling and ToS surface that is out of character for a tool whose model is "bring your
own certificate".

**Adopt (independently implemented, GPL-safe):** signed OCSP verification (VX-24). VexSign
currently delegates trust to `SecPolicyCreateRevocation` (system OCSP) and, alternatively, sends
the p12 to a third party (VX-03). A small, well-tested DER/OCSP implementation that verifies the
responder signature and reports Valid/Revoked/Unknown would remove the third-party dependency and
give per-certificate status with evidence. Odysseus is the behavioural reference; the
implementation must be VexSign's own, with RFC-generated fixtures.

**Reject:** SideSign, Anisette, Apple ID login. Reasons: licence (AGPL), credential handling,
Apple ToS exposure, and the size of the subsystem relative to VexSign's product model.

---

## 8. SideStore and AltStore — install, refresh, lifecycle

Both are AGPL-3.0 and architecturally desktop-oriented (AltServer/AltDaemon/Minimuxer). Code
cannot be used. Their *designs* are the best available specification for the lifecycle VexSign
tries to implement.

**SideStore pipeline (verified):** `Core/Operations/PipelineOperations/*` implements discrete,
composable operations — `FetchProvisioningProfiles`, `ResignApp`, `InstallApp`, `RefreshApp`,
`VerifyCertificate`, `UpdateAppCertificate`, `ExportResignedIpa`, `CacheResignedMetadata` — and
`RefreshGroup` sequences them with a shared `Progress`, per-app results
(`[String: Result<InstalledApp, Error>]`), cancellation via a stored `Task`, and retained Core
Data contexts.

**SideStore `CodeSignValidator` (verified):** validates the *running* installation against the
current profile/certificate and distinguishes expired, revoked (portal / free-account limit),
different team, different account, `privateKeyLost`, `externalSigner`, `missingProfile`,
`missingCertificate`. `OCSPValidator` fetches the WWDR intermediate and performs a live OCSP
check.

**Adopt (concepts, not code):**

- The operation/pipeline model → VexSign's `SigningService`/`InstallService` design (VX-13).
- "Validate the existing installation against the identity you are about to use" → the
  certificate-lifecycle half of VX-07/VX-16. VexSign stores the certificate on `Signed`, so this
  is implementable without an Apple ID, by parsing the signature of the stored bundle.
- Evidence-first status vocabulary → reuse in the certificate UI (`Unknown` is not `Good`).

**Reject:** Apple ID auth, Anisette, minimuxer/daemon architecture, and any copy of AGPL source.

**AltStore proper** adds nothing VexSign lacks for on-device signing; its value here is the
certificate/refresh lifecycle described above and the pairing-based install semantics VexSign
already implements through `IDeviceSwift` (`InstallationProxy`).

---

## 9. LiveContainer — container architecture

**What it is.** ★13,634, AGPL-3.0, 45 Swift files plus `TweakLoader/TweakLoader.m`, `litehook`,
its own ZSign copy and `LaunchAppExtension`. It runs apps *inside* its own container without
installing them, injecting tweaks through TweakLoader, and needs JIT/pairing for full behaviour.

**Relevance to VexSign:** low, and blocked:

- The container technique depends on entitlements and a launch-extension architecture that a
  signing utility cannot host; adopting it means becoming an app runtime, not a signer.
- AGPL-3.0 → no code.
- The realistic integration is the one that already works: VexSign exports/installs a signed IPA,
  and LiveContainer can import it. A deep link ("open in LiveContainer") is possible but adds a
  coupling to a third-party runtime.

**Verdict: documented exclusion.** Keep the boundary explicit in the roadmap's "not doing" list
so it is not re-litigated every release.

---

## 10. TrollStore — alternative installation

**What it is.** ★22,489, MIT (with one BSD-4 file). Installs IPAs permanently with arbitrary
entitlements and root helpers by exploiting the CoreTrust signing bug (`Exploits/fastPathSign`,
`RootHelper`), with `ldid` for ad-hoc signatures.

**Feasibility in VexSign: none.** The mechanism is a CoreTrust vulnerability applicable only on
specific, vulnerable iOS versions, plus a helper binary carrying platform entitlements. A
sandboxed App Store/enterprise-signed app cannot reproduce it, and nothing here should depend on
a bug that Apple fixes. What *is* possible and cheap: detect that
TrollStore is installed and offer "Open in TrollStore" / "Install via TrollStore" for users who
already have it. That is a small convenience, not a signing capability, and it belongs at the
bottom of the backlog (VX-26).

---

## 11. Zsign — the engine

**What it is.** MIT, ★1,940, pushed 2026-10-20. The signing engine behind every project in this
document. VexSign consumes it through the `claration/Zsign-Package` Swift wrapper pinned at
`6ffe703` (2025-07-27).

**Verified capability delta (pinned wrapper vs upstream source, 2026-10-20):**

| Capability | Pinned wrapper (`6ffe703`) | Upstream today | Impact on VexSign |
| --- | --- | --- | --- |
| Per-extension provisioning (`-m` repeated) | ✗ (single `prov`) | ✓ | Apps with widgets/extensions need a wildcard profile (AX-08) |
| Inject dylibs into extensions (`-P`) | ✗ | ✓ | Tweak injection into appex requires manual work |
| Certificate/OCSP check (`-C`) | ✗ (wrapper has `checkRevokage` only) | ✓ with OCSP | Could replace remote checker if adopted |
| Metadata + icon extraction (`-x`) | ✗ | ✓ | VexSign has its own readers |
| Cache for fast re-sign | present internally (`.zsign_cache` in `bundle.cpp`) | exposed, improved | Re-sign speed |
| Remove provisioning (`-R/--rm_provision`) | internal flag with **inverted semantics** | explicit CLI flag, correct meaning | Call-site polarity must be re-derived (audit §3.3) |
| Remove extensions/watch/UISupportedDevices, min-version, docs flags | ✗ (VexSign implements in Swift) | ✓ | VexSign's Swift implementations are fine; no need to switch |
| Ad-hoc signing | ✓ | ✓ | — |
| SHA-256-only CD (`-2`) | ✗ | ✓ | Optional compatibility lever |

**Verdict: upgrade (VX-09), after VX-06 provides a verification oracle.** The upgrade is not a
one-line submodule bump: the wrapper is a separate API (`Zsign.sign(...)`) and the polarity/flag
changes must be re-verified against the new engine's source. Multi-profile support (VX-08) is the
reason to do it at all.

---

## 12. Capability matrix

Legend: ● present and verified in source · ◐ partial/heuristic · ○ absent.

| Capability | VexSign | Feather | Ksign | RyukSign | KorSign | MySign | NexStore | Odysseus | SideStore | LiveContainer |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| On-device Zsign signing | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| Per-extension provisioning | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ● | ● |
| Post-sign verification | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ◐ | ● | ● |
| Profile/entitlement compatibility check | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ◐ | ● | ◐ |
| Certificate provisioning (Apple ID) | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ● | ● | ○ |
| Signed OCSP verification | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ● | ● | ○ |
| Local HTTPS (`itms-services`) install | ● | ● | ● | ● | ● | ● | ● | ● | ● | ○ |
| idevice/AFC install | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| Install confirmation from device state | ◐ | ○ | ○ | ○ | ● | ○ | ○ | ◐ | ● | ● |
| Installed-app detection | ○ | ○ | ○ | ○ | ● | ○ | ○ | ● | ● | ● |
| Tweak injection (ElleKit/Substrate) | ● | ● | ● | ● | ● | ● | ● | ● | ○ | ● |
| Tweak library + per-app defaults | ◐ | ○ | ● | ● | ● | ● | ○ | ◐ | ○ | ◐ |
| IPA explorer / file editor | ● | ○ | ● | ● | ● | ● | ○ | ◐ | ○ | ◐ |
| Repository builder/validator | ● | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| Encrypted backup container | ● | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ◐ | ◐ |
| Widgets / Live Activities | ● | ● | ◐ | ● | ● | ● | ○ | ◐ | ● | ○ |
| Companion apps (TV/vision/watch) | ● | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| Automated test suite | ● | ◐ | ○ | ○ | ○ | ○ | ○ | ◐ | ● | ● |
| Tests executed in CI | ○ | ◐ | ○ | ○ | ○ | ○ | ○ | ◐ | ● | ● |
| Feature-status honesty doc | ● | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ◐ | ◐ |

The matrix is the point of the exercise: VexSign's differentiators (repository tooling, backup,
companions, tester discipline) are real, and its deficits against the *non*-Feather references are
concentrated in exactly three areas — signing verification, install confirmation, and identity
lifecycle. Those are, in order, VX-06/07/08, VX-05/16, and VX-24.

---

## 13. Adoption decisions

| # | From | Item | Decision | Where |
| --- | --- | --- | --- | --- |
| 1 | KorSign | Install-confirmation state machine + LaunchServices probe | **Adopt model** (independent implementation, GPL attribution) | VX-05 |
| 2 | SideStore | Operation/pipeline decomposition, refresh semantics | **Adopt concept** (no code, AGPL) | VX-13 |
| 3 | SideStore / Odysseus | Validate existing install against current identity | **Adopt concept** | VX-07/16 |
| 4 | Odysseus | Signed OCSP (RFC 6960) status | **Adopt behaviour, re-implement** (SideSign is AGPL) | VX-24 |
| 5 | Zsign upstream | Multi-profile, `-P`, `-C`, cache | **Adopt** (MIT) after VX-06 | VX-08/09 |
| 6 | MySign | Consolidated default-tweaks screen | **Adopt UX** (VexSign's model already exists) | VX-23 |
| 7 | Feather family | Tweak/file-manager/download behaviours | **Reference only** — already superseded | — |
| 8 | NexStore | NexCerts catalogue | **Contain** (re-label + consent) or remove | VX-04 |
| 9 | Odysseus / SideStore | Apple ID provisioning + Anisette | **Reject** — AGPL, credentials, ToS, product fit | — |
| 10 | LiveContainer | Container runtime / TweakLoader | **Reject** — AGPL + architecture | — |
| 11 | TrollStore | CoreTrust install | **Reject** — infeasible; optional deep link only | VX-26 |
| 12 | AltStore/AltServer | Desktop daemon, minimuxer, XPC | **Reject** — AGPL + desktop model | — |

---

## 14. What this comparison does not change

- VexSign's repository/source subsystem is ahead of every reference; nothing to import.
- Its archive-safety and transport policies are ahead of the Feather family.
- Its backup container is ahead of everything except (potentially) SideStore's, and is the only
  one with component selection.
- Its test target exists where most forks have none — the failure is that CI does not run it.

The correct conclusion is therefore not "port more features". It is: **finish the three
half-built trust boundaries (verify what you sign, confirm what you install, and control what
leaves the device), then pay down the execution/cancellation and CI debt so the rest can be
maintained.**
