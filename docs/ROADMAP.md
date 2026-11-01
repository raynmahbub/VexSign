# VexSign — prioritized engineering roadmap

Derived from [`AUDIT_2026-10-31.md`](AUDIT_2026-10-31.md) (findings `AX-nn`) and
[`REFERENCE_COMPARISON.md`](REFERENCE_COMPARISON.md) (adoption decisions).

Guiding rule: **VexSign already has more features than any project in its family. The work is to
make the existing features verifiable, cancellable and safe — not to add more of them.**

Ordering rules used below:

1. A defect that can leak a signing identity, corrupt the library, or crash on a plausible path
   comes before any feature.
2. A change the CI cannot verify comes after the CI can verify it. (This is why R10 is in
   Phase 1 and the Zsign upgrade is not.)
3. A change that requires the signing engine to move waits until an independent verification
   exists to prove it did not break signing (R6 before R8/09).
4. Architecture work is done one extraction at a time, each behind its own PR and tests — never as
   a repository-wide refactor.

Legend — effort: **S** ≤ 1 day, **M** 2–4 days, **L** > 4 days. Every task assumes a reviewable PR
against `main`, with the reality that this sandbox cannot compile Swift: **CI is the build oracle**
and "done" means green CI plus the stated tests.

---

## Phase 1 — Trust boundaries and guardrails (do these first)

### R1 · Move library writes off the main-queue Core Data context — **S**, P0

**Finding:** F1. `addSigned`/`addImported` insert and fetch on `viewContext` from detached
tasks (`Storage+Signed.swift:13,29`; `Storage+Imported.swift:13,27`; call sites
`SigningHandler.swift:205`, `AppFileHandler.swift:223`, `AppCloner.swift:120,132`). The save hops
to main; the object graph does not.

**Files:** `VexSign/Backend/Storage/Storage.swift`, `Storage+Signed.swift`, `Storage+Imported.swift`,
call sites above.

**Approach**

1. Add a single `Storage.write(_:)` API that runs on `container.performBackgroundTask`, performs
   the insert/fetch, saves, and returns the `NSManagedObjectID`.
2. Have `addSigned`/`addImported` return the ID (or accept a completion with it) instead of the
   managed object; resolve the object on the main context where the UI needs it.
3. Remove `UIImpactFeedbackGenerator` from the storage layer entirely (it is a UI concern and is
   currently created off-main); trigger haptics at the call site on `@MainActor`.
4. Keep `addCertificate` `@MainActor` (already correct) and document the contract at the top of
   `Storage.swift`.
5. Enable `-com.apple.CoreData.ConcurrencyDebug 1` for the Debug scheme so violations trap in
   development.

**Acceptance criteria**

- No `context`/`viewContext` access outside `@MainActor` code or a `performBackgroundTask` block
  (verified by grep in CI: a script that fails on `viewContext` usage in non-isolated files).
- Signing and importing still produce library entries with the same fields; `originalIdentifier`
  is preserved.
- Debug builds run with Core Data concurrency assertions enabled and pass the manual flows.

**Tests:** new `StorageConcurrencyTests` — concurrent `addImported`/`addSigned` (e.g. 20 tasks)
against an in-memory store; assert row count, that every returned ID resolves, and that no
assertion fires.

**Risk:** low; merge semantics already configured (`automaticallyMergesChangesFromParent`).
**Rollback:** revert the two extension files and call sites.

**Status:** implemented (this PR). What shipped, and where it deliberately differs
from the plan above:

- `Storage.write(_:)` and `Storage.object(_:)` in `Storage.swift`. One private-queue
  write context is created in `init` and every write goes through
  `context.perform`, which serialises them. Per-call `newBackgroundContext()`
  (the literal reading of "run on `performBackgroundTask`") would have moved the
  `sortIndex` read-modify-write race from the main queue to the background queue
  instead of removing it - 20 concurrent imports would all have read the same
  lowest index.
- `addSigned`/`addImported` are `async throws`, return `NSManagedObjectID`, and
  take `certificateID: NSManagedObjectID?` instead of a `CertificatePair`
  (step 2, plus the relationship re-fetched on the write context).
- Haptics: the storage layer no longer imports UIKit at all; `Haptics.lightImpact()`
  (`VexSign/Utilities/Haptics.swift`) owns the main-actor hop. Rather than moving
  the trigger to ~12 call sites blind, the feedback keeps its current timing but
  is now guaranteed to run on the main thread. Step 3 is done in substance, not
  literally.
- `Storage(inMemory:)` now uses an `NSInMemoryStoreType` description instead of a
  SQLite store at `/dev/null`, and skips both the destructive load-recovery path
  and the UserDefaults migration flag. Without that, the first storage test would
  have deleted the host app's library folders.
- `AppFileHandler` lost its 10-second `DispatchWorkItem` watchdog: it existed to
  bound a view-context deadlock that the write boundary removes.
- Core Data concurrency assertions are enabled for the Debug app scheme
  (`VexSign.xcscheme`). Not for the test action yet - see below.

**Not done, deliberately:** the `@MainActor` sweep of `Storage.context` and the
proposed grep guard. Marking `context` `@MainActor` is the only enforcement the
compiler can actually check, but it re-isolates ~30 call sites (Vapor request
handlers, the companion bridge, several managers) and this sandbox cannot compile
Swift; it needs its own PR with an Xcode pass. A grep over `viewContext` cannot
distinguish isolation and would fire on correct code, so the runtime assertion
plus the tests below are what actually catch a regression. Tracked as **R1b**.

**Tests:** `VexSignTests/StorageConcurrencyTests.swift` - 20 concurrent imports,
10+10 mixed signed/imported writes, ID resolution including the certificate
relationship, rollback on a throwing write, and a clean in-memory store. Not
executed here (no toolchain); the Unit tests workflow is the oracle.

---

### R1b · Make the storage boundary compiler-enforced — **S/M**, P1 (follows R1)

**Motivation:** R1 put every background write on one private context and enabled the
runtime assertion in Debug, but `Storage.context` is still reachable from any queue and
nothing in the type system says otherwise. The write API makes the dangerous pattern
awkward; this task makes it impossible.

**Files:** `VexSign/Backend/Storage/Storage.swift` and every file that touches `context`
(`Backend/Observable/StorageManager.swift`, `Utilities/CertificateExpiryMonitor.swift`,
`VexSignApp.swift`, plus whatever the compiler reports after the annotation).

**Approach**

1. Mark `context`, `saveContext`, `clearContext`, `countContent`, `object(_:)` and the read
   helpers `@MainActor`.
2. Fix the call sites the compiler reports — Vapor request handlers and the companion
   bridge get an explicit `await MainActor.run { }` (or a plain `Sendable` snapshot), not an
   unchecked escape.
3. Only then add a CI guard, and only if it adds something the compiler does not: a raw
   grep over `viewContext` cannot see isolation and would fire on `@MainActor` code.

**Acceptance criteria**

- `-com.apple.CoreData.ConcurrencyDebug 1` is enabled in the **test** action as well, and the
  unit-test job is green with it.
- No `@preconcurrency`, `@unchecked Sendable` or `nonisolated(unsafe)` was added to silence a
  diagnostic; each one, if it survives review, names what is actually safe.

**Risk:** medium only in the sense that it touches many files without behavioural intent.
**Rollback:** revert the annotations; R1 keeps working either way.

**Status:** runtime half implemented; the annotation half is re-scoped to **R1c**.

What shipped:

- `StorageConcurrency.requireMainQueue()` — a Debug-only tripwire that logs a fault when a
  view-context mutation runs off the main thread. It sits at the top of every mutation entry
  point: `saveContext`, `clearContext`, `countContent`, `addCertificate`, `deleteCertificate`,
  `deleteApp`, `deleteApps`, `updateAppName`, `updateDescription`, `addSource`, `addSources`,
  `deleteSource`. `_migrateSortIndexIfNeeded` saves the view context directly instead of calling
  `saveContext()`, because it runs inside `init` on whatever thread created the store.
- `-com.apple.CoreData.ConcurrencyDebug 1` is now in the **TestAction** of both the `VexSign` and
  the `VexSignTests` schemes (`VexSignTests` sets `shouldUseLaunchSchemeArgsEnv="NO"` so CI cannot
  lose the flag by editing a launch configuration). A violation traps the test run instead of
  corrupting a store.
- One real violation found and fixed: `FR.handleSource` created an `AltSource` row inside an
  `NBFetchService` completion, which runs on a global queue. The decision and the insert now happen
  on the main queue (`DispatchQueue.main.sync` when the callback is off-main, direct when it is
  not), and the result is reported afterwards — no nested completion, no `Sendable` escape hatch.
- `StorageConcurrencyTests.testDeletingAfterABackgroundInsertRemovesTheRow` covers the guarded
  delete path end to end (insert via `write`, delete on main).

Why the annotations are *not* here:

`@MainActor` on `context` propagates to every helper that touches it — 5 read helpers with ~50 call
sites across 30 files, plus the 12 mutation helpers whose call sites sit in SwiftUI `View` helper
functions that are not themselves main-isolated. The build treats every new isolation warning as an
error (`.github/build-warnings-baseline.json` has 51 accepted warnings; new ones fail), so a sweep
without a compiler is a guess with a red build as the failure mode. The runtime guard earns its keep
in the meantime: it names the offending call site in Debug, and the test action traps on it.

**Tests:** the tripwire itself cannot be asserted (it is a log line), so the coverage is the
deletion test above plus the existing R1 suite running with the concurrency assertion enabled.
Not executed here; the Unit tests workflow is the oracle.

---

### R1c · Compiler-enforced isolation for the view context — **M**, P1 (follows R1b)

**Motivation:** R1b catches a background mutation at runtime. The type system should refuse to
compile it. This is the half of R1b that needs an Xcode pass, split out so it is not smuggled in
blind.

**Files:** `Backend/Storage/Storage.swift`, `Storage+Certificate.swift`, `Storage+Shared.swift`,
`Storage+Sources.swift`, and every call site of the read helpers listed below.

**Inventory** (measured, not estimated):

- `context`, `saveContext`, `clearContext`, `countContent`, `object(_:)` — the accessors to isolate.
- Read helpers that use `context`: `getAllApps`, `getAllCertificates`, `getSources`,
  `getSignedApps`, `getCertificate(from:)`, `getProvisionFileDecoded` — ~50 call sites, 30 files.
- Call sites that are already main and need nothing: SwiftUI `body`, `@MainActor` managers
  (`AutoSignManager`, `BatchJobRunner`, `UpdateAllManager`, `CleanupManager`, `PremiumManager`,
  `IPAWorkspace`, `SelfUpdateManager.installViaIDevice`), Vapor handlers already wrapped in
  `MainActor.run`.
- Call sites that will need work: SwiftUI `View` *helper functions* (not isolated by the protocol),
  `FR.handleSource`, `StorageManager.delete`, `StorageRules.pruneDuplicateSignedApps`, and any
  `Task { }` created from a nonisolated context.

**Approach**

1. Run the annotate-and-fix loop with a compiler: mark `context` `@MainActor`, fix what it reports,
   and add `@MainActor` to the `View` structs that need it. Do not guess a call site's isolation.
2. Replace the read helpers that background code needs with `Sendable` snapshots
   (`AppSnapshot`, `CertificateSnapshot`) instead of returning managed objects under `await
   MainActor.run` — the objects exist to be read on the main queue, and a snapshot is cheaper than
   a hop for the caller.
3. When the warnings are down to zero, delete `StorageConcurrency.requireMainQueue()` and keep the
   test-action flag.

**Acceptance criteria**

- No `@MainActor`-violating access remains outside `Storage`; the tripwire logs nothing in a full
  manual pass (import, sign, delete, source add, backup restore, Web Manager delete).
- `-com.apple.CoreData.ConcurrencyDebug 1` stays green in the test action.
- No new entries in `.github/build-warnings-baseline.json`.

**Risk:** medium; it is a wide, mechanical change with no behavioural intent.
**Rollback:** revert the annotations; R1b's runtime guard still holds.

---

### R2 · Make the Web Manager authenticated by default and stop LAN certificate export — **S/M**, P0

**Finding:** F2. `requireAuth` defaults to false (`WebManager.swift:51`); the Vapor server binds
`0.0.0.0` (`WebManagerServer.swift:227-232`, `ServerInstaller+TLS.swift:44-50`);
`GET /api/certs/:uuid/download` returns the p12 + profile (`WebManagerServer+HTTP.swift:169-176`);
the API token protects only `/api/sign` (`WebManagerServer+API.swift:154`); `defaultMaxBodySize`
is 2 GB.

**Files:** `WebManager.swift`, `WebManagerServer.swift`, `WebManagerServer+HTTP.swift`,
`WebManagerServer+API.swift`, `WebManagerServer+WebDAV.swift`,
`Views/Settings/Web Manager/WebManagerView.swift`, `BackupManager` (no), `SourceURLPolicy` (no).

**Approach**

1. Default `requireAuth = true` for fresh installs (migrate existing installs explicitly, not
   silently): read a new key `VexSign.webManager.authMigrated`; when unset, set auth on and show a
   one-time explanation.
2. Introduce an explicit `allowUnauthenticated` setting (default off) that requires a confirm
   dialog listing what becomes reachable.
3. Add per-route authorization: certificate export (`/api/certs/:uuid/download`, `POST /api/certs`,
   `DELETE /api/certs/:uuid`) requires auth **and** `X-VexSign-Token` when a token is configured,
   regardless of the global auth switch.
4. Add a bind mode: `LAN` (0.0.0.0) vs `This device only` (127.0.0.1). Default `This device only`
   for the WebDAV/files use case; `LAN` when the user asked for it.
5. Reduce `defaultMaxBodySize` for non-IPA endpoints (a sane per-route cap; IPA upload keeps a
   large cap).
6. Show the effective exposure in the UI (URL, auth state, bind mode) and put certificate export
   behind a separate toggle that is off by default.

**Acceptance criteria**

- A fresh install cannot reach `/api/certs*` without credentials and token.
- With `This device only`, a LAN peer cannot connect at all.
- The UI never shows a running server without showing its auth/bind state.
- Existing WebDAV workflows still work in `This device only`.

**Tests:** new `WebManagerAuthTests` — route-table test asserting every `/api/certs*` handler
consults both auth and token; config migration test (old default → migrated-once); bind-mode unit
test. (Vapor route tests can run in the test target.)

**Risk:** could lock out users who rely on unauthenticated file transfer. Mitigation: one-time
explanation + explicit opt-out, and the opt-out is remembered.
**Rollback:** flip the default and the per-route checks independently.

**Status:** implemented in this PR. Settings, policy and tests are in place; nothing was compiled
here (no Xcode in this sandbox). Where it differs from the plan above:

- The rule is a global middleware (`WebManagerSensitiveAccessMiddleware`), not per-route guards:
  `WebManagerServer+WebDAV.swift` mounts a catch-all `["**"]`, so one forgotten route is a hole.
  `WebManagerAccessPolicy.requiresSensitiveAccess` classifies `/api/certs*`, `/api/sign` and every
  `DELETE /api/*` *after* normalising the path (percent-decoding, case, duplicate and trailing
  slashes), so `/API/CERTS//<id>/` cannot slip past it.
- A configured token is **required** on those routes (401 otherwise) and is also accepted in place
  of Basic auth everywhere else — the Apple TV and Vision companions have a token field but no
  password field, so the token is their credential. The UI says a token is a full credential.
- "No password" no longer implies "open to the LAN": `effectiveBindMode` downgrades to `127.0.0.1`
  unless the user confirms *Allow This Network*, and the down-grade is shown, not silent.
- `defaultMaxBodySize` is 32 MB globally instead of per-route: streamed uploads (WebDAV PUT, the
  upload page) never hit the cap in the first place, and a 2 GB buffered body was the real
  denial-of-service surface.
- Certificate download is a separate switch, off by default, returning 403 with a pointer to the
  setting; `WebManager.html` prints the server's message instead of "network error".
- `ServerInstaller+TLS.swift` still binds `0.0.0.0` — it starts an unrelated installer listener and
  never serves certificates, so changing it is a separate decision.
- Migration is one-shot (`VexSign.webManager.authMigrated`); the token moved to the Keychain
  (`webManager.apiToken`) and the legacy `UserDefaults` value is removed only after a successful
  write.

**Tests:** `VexSignTests/WebManagerAccessTests.swift` (12 cases): sensitive/open route matrix, every
`DELETE /api/*`, path spellings, token matrix, bind-mode matrix, settings migration. Pure policy —
no Vapor server is started, so they run on any host. Not executed here; the Unit tests workflow is
the oracle.

---

### R3 · Remove the remote certificate checker; keep OCSP on-device — **S**, P0

**Finding:** F3. p12 + password POSTed to `certchecker.novadev.vip`
(`CertificateStatusManager.swift:89,282-316`). On-device path already exists
(`CertificateInspector.swift:65-80`, `SecPolicyCreateRevocation` + `kSecRevocationOCSPMethod`).

**Files:** `Backend/Observable/CertificateStatusManager.swift`,
`CertificateDashboard/CertificateInspector.swift`, `CertificateDashboardView.swift`,
`Views/Settings/Certificates/*`.

**Approach**

1. Delete `_fetchAppleStatus`/`_multipartBody`/`_checkerURL` and the consent alert that governs
   them.
2. Route "check status" to the existing on-device inspector; keep the existing
   `Unknown ≠ Good` vocabulary.
3. Migrate stored remote statuses to `unknown` with a note that they were produced by a removed
   service; do not present them as current.
4. Keep the result cache (no p12 in it) and its tests.

**Acceptance criteria**

- No code path serialises the p12 or its password into an `URLRequest`.
- "Check now" works offline-degraded (Unknown) without crashing.
- `BatchCertChecker` still aggregates on-device results.

**Tests:** extend `MissingFeatureTests.testCertCheckResultStatusMapping`; new test asserting the
status store never contains a p12 (grep + unit); remove the remote-service test fixtures.

**Risk:** users lose the remote verdict. It is redundant and unsafe; R24 restores better
evidence.

**Status:** implemented in this PR. Not compiled here (no Xcode in this sandbox).

- `CertificateStatusManager` is now a cache of on-device OCSP results and nothing else: the
  checker URL, the multipart body, the response parser, `CertificateStatusError` and the
  `apiStatus` initialiser are gone, so no code path can serialise a p12 or a password into a
  `URLRequest`. `CertificateAppleStatusSnapshot` became `CertificateRevocationSnapshot`
  (status word + inspector sentence + date).
- The consent alert and its `VexSign.security.allowLegacyCertificateUpload` switch are removed from
  `CertificateDashboardView`; the section says what OCSP actually sends.
- Stored remote verdicts are discarded rather than reinterpreted: the storage key moved to
  `VexSign.certificate.revocationSnapshots` and the old key plus the consent switch are deleted on
  launch. An old verdict was produced from an uploaded key, so presenting it as current would
  launder third-party evidence into the UI.
- `refreshStatusIfNeeded` (called as cells appear) still refuses to re-check inside the 30-minute
  window, and an offline or unanswered query resolves to `Unknown`, never `Signed`.
- `BatchCertChecker` already aggregated `CertificateInspector` results and is untouched.

**Tests:** `VexSignTests/CertificateRevocationTests.swift` (5 cases): OCSP-to-badge mapping, the
freshness window including backwards clock skew, and a persistence-shape test that fails if the
cached JSON ever grows a key-material field. `EcosystemTests.testUnsignedOrUnknownIsNotGoodCertificateEvidence`
now exercises the OCSP initialiser. Not executed here; the Unit tests workflow is the oracle.

---

### R4 · Contain or remove the NexCerts third-party catalogue — **S/M**, P0/P1

**Finding:** F4. `NexCerts` downloads p12 + profile + password from `sideloading.net`
(`NexCerts.swift:14-60`); entry point labelled "Official (NexCerts)"
(`CertificatesView.swift:121`).

**Decision required from the owner.** Two acceptable outcomes:

- **Remove** the feature (recommended): delete `NexCerts.swift`, `OfficialCertificatesView.swift`,
  the entry point and its strings. Lowest risk, no trust dependency.
- **Contain:** rename to "Community certificate catalogue (unofficial)", show the host, expiry,
  revocation status and the fact that the identity is shared; require an explicit acknowledgement
  before the first import; never auto-retrieve the password without displaying its origin; add
  the host to the security settings as a distinct, revocable data source.

**Acceptance criteria (either branch):** no UI calls a third-party certificate "official"; no
certificate import happens without an explicit user acknowledgement naming the source; the source
host is visible before download.

**Tests:** UI-logic test for the acknowledgement gate; documentation update in
`docs/SECURITY_REVIEW.md`.

**Status:** implemented in this PR — **contained**, on the owner's decision. Not compiled here.

- `OfficialCertificatesView` → `CommunityCertificatesView` (file and type renamed), and the
  Settings entry reads "Community Certificates (Unofficial)". The word "Official" is gone from
  the UI and from `Localizable.xcstrings`, where eight keys that described the old behaviour were
  deleted rather than left to rot.
- The list is behind a gate. Before the catalogue is *fetched* — not just before an import — the
  view names the host, and states that the identity and its password are published together, that
  anyone can sign an app claiming to come from it, that its owner or Apple can revoke it at any
  time, and that VexSign can only check that the password opens the certificate.
- The acknowledgement is stored as the acknowledged *host* (`nexCerts.acknowledgedHost`), not a
  boolean, so the catalogue cannot move to a second host and inherit consent the user gave for the
  first. "Turn Off This Source" erases it and dismisses.
- Every import is confirmed on its own, naming the certificate and the host, and the confirmation
  says the password is downloaded with it. `_import` re-checks the acknowledgement before it
  downloads anything.
- `NexCerts.downloadURLs(for:)` is now the only place a catalogue URL is built, and it is pinned
  by a test; downloads are capped at 16 MB (declared length, then actual length — a host that lies
  about its length can still overrun the buffer, which is why the streaming fix belongs in R21).
- Also removed: the "NexCerts" branding from user-visible error text.

**Tests:** `NexCertsSourceTests` in `VexSignTests/EcosystemTests.swift` — fresh install acknowledges
nothing, the disclosure host matches the host every URL points at, `https` only, acknowledgement
remembered, an acknowledgement for another host does not count, revoking forgets it.

---

### R10 · Run the unit test suite in CI — **S**, P0 (blocks everything else)

**Finding:** F10. 78 tests, 7 files; no workflow runs `xcodebuild test`.

**Files:** new `.github/workflows/ci.yml`, new `.github/scripts/select_simulator.py`,
`Makefile` (`make test`).

**Approach** (as implemented — see *Status* below)

1. macOS job on the `VexSignTests` scheme, not `VexSign`: `-only-testing:VexSignTests`, Debug,
   `CODE_SIGNING_ALLOWED=NO`, `-parallel-testing-enabled NO`. The suite touches process-wide state
   (UserDefaults, the shared `Storage` singleton, `SourceURLPolicy`'s opt-in flag), so parallel
   execution would buy minutes and cost determinism. The scheme's testable is marked
   `parallelizable = YES`; the flag overrides it per run without editing the scheme.
2. Destination is resolved at run time by `.github/scripts/select_simulator.py` (iOS runtimes only →
   iPhone only → newest runtime → newest generation → booted → name). Pinning
   `name=iPhone 16` is what makes test jobs rot when Xcode renames the device list; the script
   also fails with an actionable message instead of an opaque destination error.
3. Same cache key shape as `ci.yml` (build job) (`spm-${{ runner.os }}-<xcode>-<Package.resolved>`),
   so the two jobs share one SwiftPM checkout.
4. Annotate and summarise via `.github/scripts/xcodebuild_report.py` with
   `--warnings-as-errors false`: `build-check` owns the warnings verdict, this job only answers
   "did the tests pass". The reporter gained a `--title` flag (default unchanged) so the summary
   reads "Unit tests" instead of "Build check".
5. Trigger on PRs to `main`, on push to `main` (path-filtered to Swift/plist/entitlements/xcstrings
   and the project/workspace), and `workflow_dispatch`. Upload the `.xcresult` + raw log on every
   run (14 days); on failure also print `-showdestinations`.
6. `make test` mirrors the job (`SIMULATOR=auto` by default, or an explicit destination).

**Status:** implemented in this PR. The job has not been executed yet — this sandbox has no Xcode,
so the first CI run is the oracle. Everything that *could* be verified locally was: the simulator
picker against a fixture with non-iOS runtimes, unavailable devices and duplicate names; the empty
inventory and missing-`xcrun` exits; the workflow YAML parses; `make test` fails with the intended
guidance when no simulator exists, and bare `make` still runs `all`.

**Acceptance criteria**

- A deliberately failing test fails the PR.
- If the first run is red for reasons that predate this PR, that is the point of the task: fix or
  quarantine in the same PR and record it.
- The job is green on the current tree (fix or quarantine any pre-existing failures in the same
  PR, with the quarantine listed in `docs/FEATURE_STATUS.md`).
- Runtime under ~10 minutes with caching.

**Risk:** none to the app; possible immediate red if the suite does not compile on a real
toolchain. That is information, not a regression — fix forward in the same PR.

---

### R11 · Never write an unencrypted backup containing private keys — **S**, P1

**Finding:** F9. `BackupCrypto.seal` returns plaintext when the password is empty
(`:40-44`); the manifest includes `cert.signingPassword` (`BackupManager.swift:211`); the UI
suggests an empty password (`BackupView.swift:67`).

**Approach**

1. If `.certificates` is included, require a non-empty password (minimum length + confirmation).
   If the user wants no password, force `.certificates` off and say why.
2. Always envelope-encrypt the archive: a device-held random key in the Keychain wraps the
   payload, and the user password (when present) wraps the same key. This gives a consistent
   format and removes the `plainMagic` path.
3. Verify on restore: authenticated decryption already fails closed; add an integrity summary
   (files + counts + hashes) shown before committing.

**Acceptance criteria:** no produced backup file begins with the plaintext magic; certificate
backups always require a password; restoring an old plaintext backup still works with a warning.

**Tests:** extend `testBackupCryptoEmptyPasswordIsPlain` into
`testCertificateBackupsAreNeverPlaintext`; round-trip for both envelope paths; tamper detection.

**Status:** implemented in this PR. Not compiled here (no Xcode in this sandbox).

- `BackupCrypto` writes **`VEXBK2`** only: a random per-backup content key encrypts the payload,
  and that key is wrapped by either a PBKDF2 key from the password or a 32-byte device key kept in
  the Keychain (`backup.deviceKey`). `seal` can no longer return plaintext, and the old `VEXBK0`
  writer is gone.
- The two wraps are exclusive rather than layered. A password-protected backup is *only* openable
  with that password — keeping a device wrap alongside it would let anyone holding the device skip
  the password, which is the thing the password is for. A passwordless backup is device-bound, and
  the UI says so before the user picks it.
- Reading is backwards compatible: `VEXBK2` (new), `VEXBK1` (password-only, earlier versions),
  `VEXBK0` (plaintext). A `VEXBK0` file is recognised by `isLegacyPlaintext` and the restore flow
  shows "this is not encrypted, it holds private keys in the clear" before opening it.
- `needsPassword(_:)` replaced the blanket `isEncrypted(_:)` prompt, so a device-bound backup opens
  without asking for a password it does not have.
- Inclusion policy: `BackupManager.makeBackup` throws `certificatesNeedPassword` when
  `.certificates` is requested with fewer than 8 characters, and `BackupComponentsView` refuses to
  switch the certificates row on until the password is long enough and confirmed. The certificates
  row is never silently dropped — the confirm button disables with an explanation instead.
- Restore integrity: `open()` returns a `BackupIntegrity` (SHA-256 of the decrypted pack, and how
  many manifest certificate folders are actually present), shown above the component picker.
- `Failure` is `Equatable` so the tests can assert the exact refusal.

**Tests:** `StabilityAndArchitectureTests` — `testBackupCryptoRoundTrip` (password path, now via the
public `isEncrypted(Data)`), `testPasswordlessBackupsAreEncryptedNotPlain`,
`testTamperedBackupFailsClosed`, `testLegacyPlaintextBackupIsStillReadableAndFlagged`,
`testCertificateBackupsRequireARealPassword`. Not executed here; the Unit tests workflow is the
oracle.

---

## Phase 2 — Signing correctness

### R6 · Verify what was signed — **M**, P1

**Finding:** F6. After `Zsign.sign` returns, nothing inspects the result
(`SigningHandler.swift:151-180`).

**Files:** new `VexSign/Utilities/Signing/SignatureVerifier.swift` (+ tests), `SigningHandler.swift`,
`FR.swift`, `DirectInstaller.swift` (reuse).

**Approach**

1. Implement verification over the produced bundle:
   - main executable and each nested Mach-O carries a valid `LC_CODE_SIGNATURE` (reuse
     `MachOEntitlements.hasCodeSignature` and extend with CodeDirectory parsing);
   - `_CodeSignature/CodeResources` exists and covers the bundle's files;
   - `embedded.mobileprovision` is present when the profile was meant to be embedded;
   - the profile's `application-identifier`/wildcard matches every bundle ID in the tree;
   - signed entitlements are a subset of the profile's entitlements;
   - profile and certificate are unexpired.
2. Return a typed result (`ok`, `warnings`, `failures`) with per-item detail; surface it in the
   signing log and in the install sheet.
3. Block install/export on failures; allow "install anyway" only with an explicit confirmation
   that names the failing check.
4. Use the verifier in `DirectInstaller` instead of its current two-signal check.

**Acceptance criteria**

- Signing a fixture bundle produces `ok`; deleting `_CodeSignature` produces a failure with the
  right reason; swapping the profile for an unrelated App ID produces a failure.
- The verification runs in under ~200 ms for a 200 MB bundle on device (measure and log).

**Tests:** fixture-based unit tests for each failure mode; golden test using a pre-signed sample
bundle stored as a test resource (no private key needed to verify).

**Risk:** false negatives block installs. Mitigation: ship the verifier as *warnings first* for one
release (log-only), then promote to blocking once the device pass confirms the rules.

**Status:** implemented, in the warnings-first shape this section asks for. Not compiled here.

- New `VexSign/Utilities/Signing/SignatureVerifier.swift`. It reads structure, not hashes: the
  `LC_CODE_SIGNATURE` load command on the main and nested executables, `_CodeSignature/CodeResources`,
  the embedded profile (via the existing `CertificateReader`), and the entitlements actually sealed
  into the executable (via the existing `MachOEntitlements`, which already walked the superblob for
  keychain isolation). Nothing new parses Mach-O or CMS.
- Checks: bundle present, executable present, `_CodeSignature/CodeResources` present, executable
  signed, each nested bundle signed (warning), profile present when one was expected, profile
  readable, profile unexpired, profile's `application-identifier` covers the app, nested identifiers
  covered (warning), signed entitlements granted by the profile.
- `Expectation` makes the check relative to what was asked for: `freshlySigned` requires a profile
  unless `removeProvisioning` is set, and carries the bundle ID the user requested so a run that kept
  the old identifier is caught.
- Errors and warnings are separate. Only six things fail: no bundle, no executable, no
  CodeResources, unsigned executable, missing profile when one was required, expired profile,
  identifier not covered, and an entitlement the profile does not grant. Everything the verifier
  cannot establish — an unreadable profile, unreadable entitlements, unsigned nested bundles — is a
  warning. `tolerantEntitlementKeys` (keychain groups, `get-task-allow`, team identifiers) is
  warning-only because VexSign rewrites some of them itself.
- Wired into `SigningHandler.modify()` after `ZsignHandler.sign()` and before the bundle moves into
  the library, so it describes the bytes that are kept. Every issue goes to `SigningLog`, so it is
  in the signing log the UI already shows, and the report is kept on `SigningHandler.verification`.
- `DirectInstaller` now delegates to the same verifier instead of its own two-signal check, keeping
  its struct for the call sites that predate it. A report with failures throws the new
  `verificationFailed` case, which both install entry points turn into a confirmation that names the
  failing checks; `install(_:allowingIssues:)` is the only way past it, and it can never bypass
  "there is no signature at all".
- Deliberately *not* done here: the normal signed→`InstallQueue` path is not gated, because the
  verdict does not survive as far as the `Signed` row without a schema change. That promotion
  (persist the verdict, block in `InstallQueue`, drop the allowance after a release) is R6b and
  should follow the device pass this section asks for.

**Tests:** new `VexSignTests/SignatureVerifierTests.swift` (16 cases) with synthetic fixtures — a
Mach-O whose only load command is `LC_CODE_SIGNATURE` pointing at a real entitlements superblob, an
XML profile, and a CodeResources plist. Covers both acceptance cases by name (deleting
`_CodeSignature` fails; a profile for an unrelated App ID fails) plus wildcard coverage, expiry,
entitlements, the tolerated keys, declared-vs-produced identifiers, and a timing assertion on the
fixture. The byte layout was validated against `MachOEntitlements`' parsing rules before shipping.

---

### R7 · Certificate ↔ profile ↔ bundle compatibility engine — **M**, P1

**Finding:** F7. `PreflightChecks` never compares the app to the profile.

**Files:** new `VexSign/Utilities/Signing/ProfileCompatibility.swift` (+ tests),
`Backend/Observable/PreflightChecks.swift`,
`Views/Signing/Shared/SigningOptionsView.swift`, `Views/Settings/Certificates/*`.

**Approach**

1. Parse from the profile: `application-identifier`, `Entitlements`, `TeamIdentifier`,
   `ExpirationDate`, `ProvisionedDevices`, `get-task-allow`, wildcard-ness, and the certificate
   list (the CMS carries the developer certificate; `CertificateReader` already decodes the
   payload).
2. Compute issues: explicit App ID vs target bundle ID mismatch; extension bundle IDs not covered;
   requested entitlement not granted (app groups, associated domains, push, iCloud, keychain
   groups); profile expired; certificate not in profile; device not provisioned (when list is
   present); PPQ/JIT mismatch (already partly covered).
3. Surface as `PreflightIssue`s with severity and a one-tap fix where one exists (e.g. propose a
   bundle ID that the profile covers, or offer to strip an entitlement).
4. Reuse the same engine to label certificates when picking one for an app ("covers this app",
   "wildcard", "cannot sign this app").

**Acceptance criteria**

- A mismatched profile is a *blocking* preflight issue before signing, not an install failure
  afterwards.
- The certificate picker shows a compatibility badge per certificate.
- No network access is required for any of it.

**Tests:** fixtures for wildcard/explicit/enterprise/dev profiles (the suite already contains
profile fixtures) and for entitlement subsets; table-driven expectations.

**Status:** implemented in this PR. Not compiled here.

- New `VexSign/Utilities/Signing/ProfileCompatibility.swift`: a pure engine over the decoded
  `Certificate` the app already stores (`CertificateReader`), returning a `Verdict` for the picker
  and `Issue`s for preflight. Checks: profile expiry, App ID coverage (explicit, wildcard, prefix
  wildcard), uncovered extensions, requested entitlements the profile does not grant (array
  *subsets* are fine, only genuinely missing elements fail), team mismatch, certificate-not-in-profile
  and device-not-provisioned. The tolerant key list is shared with `SignatureVerifier` so preflight
  and the post-sign check can never disagree.
- `PreflightChecks` runs it when a certificate is selected, as **blocking** issues — which means the
  existing "Sign Anyway" confirmation in `SigningView` already names the reason. A mismatched
  profile can no longer reach the install stage.
- Certificate picker: `CertificatesCellView` gained an optional `target`, threaded from
  `SigningView` through `CertificatesView`, and adds one pill ("Signs this app" / "Wildcard · signs
  this app" / "Can't sign this app" / "Unknown"). In Settings there is no app, so no pill.
- Certificate ↔ profile pairing: `CertificatePair.appliedCertificateDER` reads the leaf certificate
  out of the stored p12 with `SecPKCS12Import` (no keychain import, no prompt) and compares
  fingerprints with the profile's `DeveloperCertificates`. When the Keychain is locked this returns
  nil and the check is skipped rather than guessed at.
- Devices: the check exists and is tested, but a jailed app cannot read its own UDID, so production
  passes `nil` and the check stays silent. VexSign's UDID tool is a web session that is deliberately
  not stored; if that ever changes, this is the field to fill.
- Nested identifiers are read from the app bundle (`PlugIns`, `Extensions`, `Watch`) so an uncovered
  extension is a warning *before* signing rather than a broken install after it. R8 owns the fix.
- **Bug fixed, found while building this:** `SignatureVerifier.coverage` required the *bundle*
  identifier to carry the team prefix, so every explicit profile would have looked like a mismatch.
  The team prefix belongs to the profile and to entitlement values, not to bundle ids. Coverage is
  now team-insensitive (team identity is checked separately, by this engine) and R6's tests were
  corrected — one of them had encoded the wrong rule.

- **Guard added after this class of mistake bit twice:** `swiftc -parse` does not resolve imports,
  so a file that calls `String.localized` without `import NimbleExtensions` parses clean and fails
  in a real build. Four files were in that state (two from R2, two from this work).
  `quick_check.py` now has a `cross-module-imports` check with a small symbol→module table, and it
  was verified by injecting a violation and watching it fail. All four files are fixed.

**Tests:** new `VexSignTests/ProfileCompatibilityTests.swift` (21 cases): a verdict table over
pattern/bundle pairs, expiry, missing profile, team mismatch, granted/ungranted/subset entitlements,
the tolerant keys, extension coverage, certificate-in-profile (match, mismatch, absent), and device
provisioning including the in-house and unknown-UDID cases.

---

### R8 · Per-extension provisioning and nested signing — **L**, P1 (depends on R6, R9)

**Finding:** F8. One `provisionPath` for the whole tree (`ZsignHandler.swift:53-66`); pinned
engine has no multi-profile support.

**Approach (preferred):** bump `Zsign` to a commit whose wrapper accepts multiple profiles,
extend `ZsignHandler.sign` to pass a profile mapping, and let `SignatureVerifier` (R6) prove the
result. **(Fallback):** sign nested bundles in a separate pass with their matching profile, then
sign the outer bundle.

**Blocked on the engine (verified in R9):** the `package` branch head does expose
`SignFolder(list<ZSignAsset>*, …)` (`src/bundle.cpp:750-764`), but it can no longer leave a profile
in a bundle at all, so it cannot be adopted; the pinned `SignFolder` takes one asset. Either way the
engine signs every nested symbol with the *outer* profile's entitlements, so the profile mapping
needs an engine change first — see R9's status block for the evidence.

**Files:** `.gitmodules` (pin), `Zsign` submodule, `ZsignHandler.swift`, `SigningHandler.swift`,
`ProfileCompatibility.swift`, signing UI (profile picker per extension), `docs/FEATURE_STATUS.md`.

**Acceptance criteria**

- An app with a widget extension signs with per-extension profiles and passes R6 verification.
  **Not met** — needs the engine change below.
- A user with only one profile still gets today's behaviour, with a warning when an extension is
  not covered. **Met**, and the warning now names the bundle, the App ID the profile carries and
  the profile the extension arrived with.
- Signing time does not regress by more than ~10% on a fixture. Not measured here: the added work
  is one directory walk per folder, before the engine starts.

**Risk:** engine change affects every sign. Mitigation: land R9 first behind a switch, run
both engines on fixtures, keep the old pin revertible.

**Status:** the engine-independent half is implemented in this PR; the signing half stays blocked on
the engine (see R9). Not compiled here; tests not run.

- **What the pin can and cannot do.** `SignFolder` takes a single `ZSignAsset` and applies it to
  every node it walks (`Zsign/src/bundle.cpp:515-544`), so a nested bundle is always signed with the
  *outer* profile's identity and entitlements. Pre-placing per-extension profiles does not help:
  the outer pass rewrites each nested signature anyway, and re-signing the nested bundles afterwards
  invalidates the outer seal. The `package` head does have the C++ overload that takes a list of
  assets (`src/bundle.cpp:750-764`), but it cannot leave a profile in a bundle at all (R9), so
  there is still nothing to adopt.
- **What landed.** `VexSign/Utilities/Signing/NestedBundleAudit.swift` enumerates the nested bundles
  that actually need a profile — `.appex` under `PlugIns`/`Extensions`, `.app` under `Watch` —
  reads each one's `CFBundleIdentifier` and the `application-identifier` of the profile it already
  ships, and classifies it against the selected profile as covered, not covered, or unknown.
  Frameworks are skipped: iOS does not require a profile for them, so they would only ever be
  noise. `unknown` is never reported as a problem — no profile, or no identifier, is the absence of
  evidence, not a failure.
- **Wired where it matters.** `SigningHandler` audits the payload after modification and before the
  engine runs, logging one line per uncovered bundle: the extension, the App ID the profile
  carries, and — when it differs — the profile the extension arrived with. `PreflightChecks` and
  the certificate picker now ask `NestedBundleAudit.requiredIdentifiers(in:removeAppExtensions:)`
  rather than scanning on their own.
- **Bug fixed on the way.** Both of those call sites demanded coverage for extensions even when
  `Options.removeAppExtensions` strips them before signing, so the preflight warned about bundles
  that no longer existed at sign time. The option is now passed through, and a stripped extension
  is not a requirement.
- **Still not done.** Picking a profile per extension, and signing with it. Both need the engine
  change above; a picker that cannot be honoured would be worse than no picker.

**Tests:** new `VexSignTests/NestedBundleAuditTests.swift` (14 cases) over app trees built on disk:
scanning extensions and watch apps, skipping frameworks and loose files, wildcard coverage, an
explicit App ID not covering a sibling, unknown-everything without a profile, a bundle with no
identifier, a blank pattern, the warning naming the bundle and its shipped profile, the summary,
an app with no nested bundles, and required identifiers with and without extension stripping.

---

### R9 · Zsign engine upgrade — **M**, P1 (after R6)

**Finding:** engine pin `6ffe703` is from 2025-07-27; upstream (MIT, 2026-10-20) has multi-profile,
`-P`, `-C`, cache improvements and a corrected `-R` meaning.

**Approach**

1. Pick a release commit; read the diff of `signing.h`, `bundle.cpp` and the CLI options.
2. Re-derive every argument at the call site from the new source — **especially** the
   provisioning flag whose polarity is inverted in the old engine (audit §3.3). Add a comment
   citing the new source.
3. Keep the wrapper surface unchanged where possible so call sites do not churn; add
   `sign(..., profiles:)` alongside the existing API.
4. Add a `.zsign_cache` hygiene step: the engine writes it relative to the process CWD; clear it
   per sign or point it at the work directory.

**Acceptance criteria:** all signing paths still pass R6; re-sign of an unchanged app is
measurably faster (cache — **not met**, see Status: the pin never reads its own cache); the removal
flag behaves as the toggle says on a device pass.

**Tests:** engine-level fixture tests (sign a sample bundle with a test identity, verify, inspect
`embedded.mobileprovision` presence for both toggle states).

**Status:** analysed in this PR. The pin stays at `6ffe703`; the newer package commit is **not**
adopted. What did land is the engine seam, the cache hygiene and the flag tests. Not compiled here;
tests not run.

- **What was compared.** The pin (`claration/Zsign-Package` @ `6ffe703`) against the newest commit
  on the same `package` branch, `c4ba9da42830` (2026-09-19, "Fix SwiftPM integration and Xcode 27
  compatibility"), which vendors upstream `zhlynn/zsign` v1.1.x; `066a3f21a5f8`, the commit before
  it, behaves the same in every point below. All three trees were read from source.
- **What the newer engine would have brought.** Per-extension profiles in the C++
  `SignFolder(list<ZSignAsset>*, …)` overload (`src/bundle.cpp:750-764`), a dylib-removal list
  (`arrRemoveDylibNames`), the `-C` certificate/OCSP check, `-P`, and the upstream hardening
  releases (v1.1.2 "write `embedded.mobileprovision` before `CodeResources` sealing", v1.1.3 "fail
  instead of sealing an unreadable file as empty").
- **Why it cannot be adopted as-is.** The fork gates the profile write on the same flag whose job
  upstream is to *delete* the profile after sealing. `src/bundle.cpp:681-689` writes
  `embedded.mobileprovision` only when the flag is `true`, and `src/bundle.cpp:184-189` then
  deletes that very file while generating `CodeResources` for the same flag, so both states end
  with **no profile in the bundle**: `true` writes and then deletes, `false` never writes. That
  would fail every install on every signing path. Upstream v1.1.3 does not have the bug — it
  writes the profile whenever the bundle has one (`src/bundle.cpp:829-836`) and uses the flag only
  to strip it afterwards (`-R`, "Remove mobileprovision file after signing").
- **A second cost.** That commit renames the modules (`ZsignSwift` → `Zsign`, C target `Zsign` →
  `ZsignC`, wrapper moved to `swift/`), so the bump is repo-wide — every `import` plus the
  `project.pbxproj` product refs — for behaviour we would then have to work around.
- **The cache criterion is not reachable from the app side.** The pin hardcodes `bForce = true`
  (`src/zsign.mm:182`) next to `bEnableCache = true` (`src/zsign.mm:218`), and `bundle.cpp` only
  reads `./.zsign_cache/<sha1>.json` when `m_bForceSign == false` (`src/bundle.cpp:556-596`).
  The cache is therefore written on every run and read on none: "measurably faster re-sign" needs
  a package change (expose `bForce`, or default it to `false`), so the criterion moves to that work
  instead of being claimed here.
- **Provisioning polarity re-derived, and unchanged.** The old call site's negation
  (`removeProvision: !_options.removeProvisioning`) is correct for this pin: the engine's flag
  means "embed", not "remove" (`src/bundle.cpp:536-544`, audit §3.3). It now lives in
  `ZsignEngine.Request.engineEmbedProvision` — one place, with the source cited — and a test pins it
  against `SignatureVerifier.Expectation.requiresEmbeddedProfile`, which `SigningHandler` derives
  from the same option, so the signer and the verifier cannot drift apart.
- **What landed.** `VexSign/Utilities/Signing/ZsignEngine.swift` is now the only place that signs
  through the engine: it builds the request, translates the provisioning intent once, folds the
  engine's two failure signals into one `Outcome`, and owns `.zsign_cache`
  (`cacheDirectory(in:)`, `clearCache(in:)`). `ZsignHandler` keeps its `sign()` / `adhocSign()` / `disinject()` surface and
  clears the cache before each run, so no other call site changed.
- **Not done, and why.** `sign(..., profiles:)` is deliberately absent: the pin's `SignFolder`
  takes a single `ZSignAsset`, and writing per-extension profiles into nested bundles by hand would
  still sign every nested symbol with the outer profile's entitlements — producing a mismatched
  extension rather than refusing it. R8 stays blocked on an engine that both embeds a profile
  and exposes `list<ZSignAsset>`.

**Tests:** new `VexSignTests/ZsignEngineTests.swift` (10 cases): the provisioning translation in both
directions, the untouched request's defaults, the signer/verifier agreement, that only the
provisioning intent differs between the two requests, a full identity request, an ad-hoc request
carrying no identity, the cache path being relative to the working directory, cache clearing
leaving neighbours alone, clearing a clean directory, and clearing twice.

---

### R13 · One signing service with events and cancellation — **M/L**, P2

**Finding:** F12. Unstructured `Task.detached` with a completion closure; no cancel; progress
constants (`FR.swift:47-120`); batch cancel only flips a flag.

**Approach**

1. Introduce `SigningRequest` (value) and `SigningService` (actor) producing
   `AsyncStream<SigningEvent>`: `.preparing`, `.modifying(step)`, `.signing`, `.verifying`,
   `.registering`, `.finished(Signed)`, `.failed(Error)`.
2. Keep `SigningHandler`'s internals as the "modify" stage; do not rewrite the pipeline.
3. Check `Task.isCancelled` between stages and inside long loops (bundle walk, zip/verify);
   make cleanup deterministic so a cancelled sign cannot leave a moved-but-unregistered bundle
   (the `clean()` guard already exists).
4. Convert `FR.signPackageFile` into a thin adapter over the service (keeping its signature so the
   seven call sites do not change in this PR); migrate call sites one at a time afterwards.
5. Wire the cancel button in the signing sheet, the task center and the Live Activity.

**Acceptance criteria:** cancelling a sign mid-way leaves no partial bundle and reports
`cancelled`; progress reflects real stages; batch signing honours cancel between and within items.

**Tests:** state-machine tests for events; cancellation test with a fake stage; "no leaked
directory" test.

**Status:** implemented in this PR. Not compiled here.

- New `VexSign/Utilities/Signing/SigningService.swift`: `SigningRequest` (a value over
  `AppInfoPresentable`, so batch jobs and fakes work unchanged), `SigningStage`
  (`.copying`, `.modifying`, `.thinning`, `.injecting`, `.signing`, `.verifying`, `.registering`,
  each with a title and an ordered progress value), `SigningEvent`
  (`stage` / `finished(Signed)` / `cancelled` / `failed(Error)`) and the `SigningService` actor
  that owns runs by request id. Events reach the caller on the main actor, in pipeline order, with
  exactly one terminal event per run.
- iOS 16 floor respected: `AsyncStream.makeStream()` is 17+, so the stream is built with the
  `AsyncStream` initialiser and an explicitly held continuation. A single consumer task delivers
  the events, which keeps the pipeline's order without a lock of our own.
- `SigningHandler` is **not** rewritten. It gained an `onStage` callback, reports the stages it
  actually reaches (thinning only when thinning runs, injecting only when injecting runs), and
  calls `Task.checkCancellation()` between stages — after the copy, before and after
  thinning/injection, before `move()`, and before the library insert. `clean()` needed no change:
  it already deletes the work directory always and the moved bundle unless it was registered, which
  is what makes a mid-run cancel leave nothing behind.
- `FR.signPackageFile` is now a thin adapter — same signature, same Live Activity, same
  `UnifiedTaskCenter` record, same background task — over `SigningService`. The six call sites did
  not change in this PR, and they get real stage progress and cancellation for free. A second
  start for the same app is refused with `SigningService.BusyError` instead of racing the first run
  for the same work directory.
- Cancel wired to real controls: the signing sheet gained a stop button beside "Show Logs"
  (`SigningService.shared.cancelAll()`), a cancelled run shows "Signing cancelled" instead of an
  error alert, `BatchJobRunner.cancel()` now stops the item already in flight rather than only the
  next one, and a cancelled batch item is marked `.skipped` — not failed — with the Live Activity
  not restarted afterwards.
- The task-centre record and the Live Activity follow the run: `.cancelled` and `.failed` both
  transition the record and end the activity, and a late stage event cannot reopen a finished one
  (`transition` already ignores terminal records).

**Tests:** new `VexSignTests/SigningServiceTests.swift` (7 cases, driven through a `SigningWork`
fake so no zsign, certificate or device is needed): stages arrive in pipeline order and the run
ends `.finished`; failures arrive as `.failed`; a `CancellationError` from the pipeline is reported
as `.cancelled` and never as a failure; exactly one terminal event per run; the run is released
once it finishes and the same app can be signed again; a second start for the same request is
refused; cancelling stops an in-flight run; `cancelAll()` stops every run.

---

### R12 · Take TLS key material out of the build — **S/M**, P2

**Finding:** F11. `make deps` downloads a private key from a Cloudflare Worker
(`Makefile:9,22-30`), and the app can re-download it at runtime (`FR.swift:190-200`,
`ServerView.swift:57`).

**Approach**

1. Generate a self-signed certificate at build time with a checked-in script (deterministic
   subject, random key, committed only for development), or keep the download but pin a SHA-256
   and fail the build on mismatch.
2. Make the runtime refresh path explicit: it is a user action that fetches a new identity for the
   local server; label it as such.
3. Document the trust assumption in `docs/RELEASING.md` and the build output.

**Acceptance criteria:** an offline `make` produces a working installer certificate; the build
fails loudly on a checksum mismatch; no silent downgrade to "no certificate".

**Status:** implemented in this PR. Not compiled here (the Makefile and scripts were run; see
below).

- **Build, offline.** `make deps` no longer fetches anything. It calls
  `Scripts/local-tls/make-dev-identity.sh`, which mints a development Root CA and leaf with
  `openssl` — deterministic subject (`CN=VexSign Development Root CA`, leaf `CN` configurable,
  default `127.0.0.1`), random key, SANs covering loopback, `localhost` and `*.local` — and writes
  the three files the server already reads (`server.crt` leaf-then-CA, `server.pem`,
  `commonName.txt`) plus `tls-identity.txt`, which records the mode, the host and the digest so the
  app can say what it shipped with. The identity is **reused** while its leaf has more than seven
  days left and the key still matches, so a CA profile a tester trusted once does not go stale on
  the next incremental build. `make deps-dev` forces a fresh one.
- **Build, release.** `make deps-release` fetches the published pack and verifies it against
  `Scripts/local-tls/pinned-pack.sha256`; a missing pin, a network failure, a missing field, a
  non-PEM file or a digest mismatch stops the build with an actionable message. The Release
  workflow runs it before `make`, so a release cannot ship an identity nobody reviewed.
  `make deps-pin` fetches, prints the digest and rewrites the pin file — the diff is the review.
  The pin ships empty on purpose: the digest of the live pack cannot be invented here, and a wrong
  pin would fail every release. **Action item for whoever cuts the next release:** run
  `make deps-pin`, read the diff, commit it.
- **No silent downgrade.** The old recipe's `|| echo warning: … building without a bundled
  certificate` is gone. Both paths either produce a usable identity or fail; `make deps` also warns
  when the identity it is reusing expires within a day.
- **Runtime refresh, explicit.** `ServerView` now shows the live identity (source, mode, host,
  expiry — `LocalTLSIdentity.Summary`) in the section footer, warns in orange when the build ships
  a self-signed development identity, and asks for confirmation before fetching, spelling out that
  the fetch replaces the identity on the device and may require re-trusting the Root CA.
  `FR.downloadSSLCertificates` validates the pack **before writing anything**
  (`LocalTLSIdentity.validate`: hostname usable, key present, every certificate parses, leaf not
  expired) and returns the installed summary; a failure leaves the previous identity untouched. A
  new "Use the Identity From This Build" action deletes the Documents override so the bundled
  identity is used again — the recovery path that did not exist.
- **Why the runtime path is validated rather than digest-pinned.** The pack rotates (the current
  identity is short-lived) and a digest baked into an old build would reject every legitimate
  refresh. Build-time pinning protects what is *shipped*; runtime validation protects what is
  *installed*, which needs to keep working between releases. Both are documented in
  `docs/RELEASING.md` under "Local install server TLS identity".
- **Reused, not duplicated:** the leaf's `notAfter` comes from `CertificateInspector.notAfter`,
  the DER walk that already exists for the same job (`SecCertificateCopyValues` is not available on
  iOS), promoted from `private` to internal. `LocalCAProfile`, `ServerInstaller.getUrl` and
  `readCommonName` are untouched.
- **Verified here:** `make deps` (fresh → development identity; second run → reuse),
  `make deps-pin`/`deps-release` without network (loud failure, exit 1), digest verification
  (match → pass, mismatch → exit 1), `openssl verify` of the generated chain against its own CA,
  and agreement between `pack_digest.py` and the Swift rule (`pack_digest.py` — digest
  `c13c21f4…` — is the vector in the tests).

**Tests:** new `VexSignTests/LocalTLSIdentityTests.swift` (16 cases): the digest vector shared with
the build script, whitespace-insensitivity, per-field sensitivity, hex shape; marker parsing
(mode/host/digest, bare digest, comments and unknown keys, missing mode, unknown mode); and the
validation refusals (empty material, unusable hostname, missing key, unreadable certificate, empty
bundle) plus the hostname table `ServerInstaller.normalizedHostname` already relied on.

---

## Phase 3 — Installation lifecycle

### R5 · Confirm installs instead of guessing — **M**, P1

**Finding:** F5. Success is inferred from `installProgress` returning to zero
(`AppInstaller.swift:372-380`; same pattern in `SelfUpdateManager.swift:342-357`).

**Files:** new `VexSign/Utilities/Installing/InstallConfirmation.swift` (pure) and
`InstalledAppProbe.swift` (adapter), `AppInstaller.swift`, `SelfUpdateManager.swift`,
`NimbleKit` (extend `UIApplication+open_private`), tests.

**Approach** (model from KorSign, independently implemented)

1. `InstalledAppProbe`: read `LSApplicationProxy.applicationProxyForIdentifier:` → isInstalled,
   isPlaceholder, version, build, bundleURL, registeredDate; read install progress phase/state and
   `ls_expectedFinalInstallPhase`. All selector lookups guarded; any missing evidence returns
   `nil`, never `false`/`true` guesses.
2. `InstallConfirmation`: phases (waiting → downloading → verifying → finished) with deadlines
   (120 s / 600 s), rules for "progress ended" (retire UI, no success claim), and confirmation
   requiring `Finished` + expected final phase + matching version/build where available.
3. OTA has no cancellation callback: map timeouts to failure with an actionable message; map the
   decline-watch path (already present) to `cancelled`, never to success.
4. Record `.appsInstalled` analytics only on confirmation.

**Acceptance criteria**

- A cancelled install is reported cancelled; a timed-out install is reported failed with a retry
  action; a successful install is reported only when the device state proves it.
- The UI distinguishes "installed", "installed (older version)", "not installed" for library apps.

**Tests:** pure state-machine tests for every transition and timeout; probe adapter tests with a
stubbed proxy; regression test asserting no analytics on failure.

**Status:** implemented in this PR. Not compiled here; tests not run.

- New `VexSign/Utilities/Installing/InstalledAppProbe.swift`: `InstalledApp` (installed,
  placeholder, version, build, bundle URL), the `InstalledAppProbing` seam, a
  `LSApplicationProxy` adapter with every selector base64-encoded and `responds(to:)`-guarded the
  way the rest of the app's private lookups are, and `InstalledState.derive(from:expecting:)`
  (`.installed` / `.installedOtherVersion` / `.notInstalled` / `.unknown`) — the derivation R16
  renders in the library. A probe that cannot answer returns `nil`; nothing is guessed.
- New `VexSign/Utilities/Installing/InstallConfirmation.swift`: a pure state machine —
  `.waitingForStart` → `.downloading` → `.verifying` → `.finished(Verdict)` — with the roadmap's
  deadlines (120 s to start, 600 s to verify, 20 s to settle). Success requires the device to
  report the app *and* the version that was sent; an older version is reported as
  `installedOtherVersion` only after the settle window (version strings lag the install);
  a missing app becomes `notInstalled`; no evidence becomes `timedOutVerifying`, **never**
  success. `cancel()` cannot take back a proven install. `InstallWatcher` is the loop that feeds
  it progress and probe readings — both injected, which is what makes it testable — and is shared
  by the OTA and IDevice paths.
- `AppInstaller`: progress still drives the ring and the PPQ heartbeat, but the old
  `hasStarted && raw == 0 → .completed` guess is gone. The verdict is what finishes an install.
  `Outcome` gained `installedOtherVersion(String?)`, so "installed, but not what you sent" is a
  thing the caller can see; `Outcome.countsAsInstall` is the single rule for
  `AnalyticsStore.record(.appsInstalled)` — cancelled and exported never count, and a failure can
  never reach it. The IDevice path is corroborated the same way: installd's completion enters the
  engine at `.verifying` instead of being believed outright.
- `SelfUpdateManager.pollInstallProgress` returns a verdict instead of a `Bool` guess: installed →
  done; dismissed prompt → idle; installed but still on the old version, rolled back, or never
  finished → a failure with the existing **Try Again** action.
- `InstallQueue` shows a toast when an install is proven but the device reports another version.
  Library-row annotation is R16's job and now has the derivation it needs.
- **Not done here:** `LSApplicationWorkspace` install-progress *phase/state* and
  `ls_expectedFinalInstallPhase` (what KorSign reads on the idevice path) are not wired — the
  IDevice install itself lives in `IDeviceSwift`, so that path is confirmed by evidence after the
  fact instead of by installd's phases.

**Tests:** new `VexSignTests/InstallConfirmationTests.swift` (16 cases): the start deadline,
progress → downloading → verifying, exact version installed, no expectation accepting any version,
older version only after the settle window, a version that catches up inside the window, a missing
app becoming `notInstalled`, unknown evidence timing out instead of succeeding, placeholders not
counting as installs, cancel during download, cancel after a proven install, the
`InstalledState` table, `countsAsInstall` (the analytics regression), and two `InstallWatcher`
end-to-end runs with a scripted counter and a fixed probe.

---

### R16 · Library reflects real installation state and signature lifetime — **M**, P1

**Depends on:** R5, R7.

**Approach**

1. Use `InstalledAppProbe` to annotate library entries: installed / not installed / version
   mismatch.
2. Parse the stored signed bundle's signature to identify the signing certificate and its expiry
   (the `Signed` entity already stores the certificate; verify it matches the binary) — the
   SideStore `CodeSignValidator` concept, implemented on VexSign's own data.
3. Warn before an install/refresh when the app in the library was signed by a different identity
   than the selected one (the "external signer / keychain breaks" case), and explain the
   consequence.
4. Surface "expiring in N days / expired" per app, feeding the existing expiry pill.

**Acceptance criteria**

- The library never claims an app is installed when the probe says otherwise (or says "unknown"
  when the probe is unavailable).
- Re-signing with a different certificate warns before it happens.

**Tests:** state derivation tests; fixture bundle → identity parsing; expiry math.

**Status:** implemented in this PR. Not compiled here; tests not run.

- **The device's answer, cached and batched.** `LibraryStatusStore` reads `InstalledAppProbe`
  and the stored bundle's signature once per app, off the main thread, throttled to 30 s per
  entry, and publishes one dictionary the list can diff against. `AppInstaller` invalidates the
  entry by identifier the moment an install is confirmed, with an epoch counter so a read that
  was already running cannot publish the answer it was about to. A read that cannot answer stays
  `.unknown` and the row says **nothing**.
- **The library stops claiming what it cannot see.** `InstalledApps.isInstalled` — the
  `canOpenURL("scheme://")` guess, which answered *no* for every app without a URL scheme and
  *yes* for apps that were already deleted — is gone. Rows badge the real state (installed,
  installed at another version, not installed), and the "Open" action is hidden when the device
  says the app is not there.
- **Which certificate the bundle carries.** `BundleSignature` walks the Mach-O's
  `LC_CODE_SIGNATURE` command into the superblob, takes slot `CSSLOT_SIGNATURESLOT`, and reads the
  DER certificates out of the CMS `SignedData` — with a bounds-checked DER reader of its own
  (`DER`), because there is no CMS decoder on iOS. `SigningIdentity` turns each certificate into
  a SHA-256 fingerprint, subject common name, serial and validity window. No Security framework:
  the same bytes give the same answer on every device, which is also why it is testable here.
- **The expiry pill counts down the right date.** The row's `CertificatePair` records what the
  user signed *with*; the bundle records what it *carries*. The pill now prefers the bundle's own
  certificate and falls back to the entity only when the bundle cannot answer. The app info sheet
  gained a **Signature** section: installed state, signer, serial, fingerprint, expiry, and one
  line saying whether that matches the certificate on the library entry.
- **Re-signing with a different identity warns first.** `PreflightChecks.signerIdentity` compares
  the bundle's certificates with the selected profile's `DeveloperCertificates` and, on a real
  mismatch, adds a warning that names both identities and says what the change costs (no in-place
  update, keychain data lost). It rides the existing pre-sign alert, so "Sign Anyway / Cancel" is
  already the choice. Batch, Update All and automation never see that alert, so `FR.signPackageFile`
  writes the same explanation to the signing log for them. A comparison that lacks certificates on
  either side is `unknown`, never a mismatch.

**Tests:** new `VexSignTests/BundleSignatureTests.swift` (28 cases): DER length forms and
refusals, children that do not fill their parent, a 40-deep nesting bound; a real openssl
certificate → common name, serial, validity and fingerprint; expiry math at the boundary; a real
CMS `SignedData` → its signer, and an ad-hoc CMS → an empty set rather than nil; superblob slot
selection, bounds refusal, and a corrupt superblob reported as unreadable rather than unsigned;
an arm64 Mach-O built byte by byte → identity through the whole path; the match matrix
(same / different / chain / unknown); `LibraryStatusStore.resolve` with a stub probe; the info
rows; and the badges.

---

## Phase 4 — Maintainability, quality gates, performance

### R14 · Extract services and split god files (incremental) — **L**, P2

**Finding:** F17 / §2.2–2.3 (1,567-line `AppStoreView`, 934-line `DownloadManager`, 54
singletons).

**Approach**

1. One extraction per PR, each purely mechanical and test-backed:
   `AppStoreView` → `AppStoreHeroSection`, `AppStoreSections`, `AppStoreSearch`;
   `DownloadManager` → `DownloadScheduler`, `DownloadPersistence`, `DownloadNotifications`;
   `VexSignApp` → `AppDelegate`, `BackgroundTasks`, `DeepLinks`.
2. Introduce protocols for the three globals that block tests: `StorageProtocol`,
   `DownloadManagerProtocol`, `SigningServiceProtocol`. Inject where a view model is constructed;
   keep `.shared` as the production instance.
3. Freeze the singleton count: a CI grep fails when `static let shared` increases.

**Acceptance criteria:** no behaviour change; test target can construct at least one view model
with fakes; largest file under ~800 lines after the first three extractions.

**Status — first slice landed (2026-11-01); the rest is scheduled work, not done.**

- **Singleton count frozen.** `tools/singleton-freeze.py` counts `static let/var shared` under
  `VexSign/` (currently **56 in 55 files**) against `tools/singleton-baseline.json` and fails when a
  file grows. Probe-verified: injecting one in an unrelated file fails the check, removing it
  passes. Wired into `ci.yml` (quick job) ("Singleton freeze"). This is acceptance criterion 3.
- **A testable seam exists.** `VexSign/Backend/Services/Downloading.swift` defines
  `PackageDownloading` — start a download, get the row back — implemented by `DownloadManager` as
  the production instance. `DiscoveryViewModel` now takes it in its initialiser
  (`init(downloads: PackageDownloading = DownloadManager.shared)`) instead of reaching for `.shared`
  inside `download(_:)`. `VexSignTests/DiscoveryViewModelTests.swift` constructs the view model with
  a fake, refuses a non-`https` URL and refuses a missing one without touching the pipeline. That is
  acceptance criterion 2, for one view model.
- **One extraction, mechanical.** The four self-contained repository views at the bottom of
  `AppStoreView.swift` (`RepositoryRow`, `RepoIcon`, `RepoMiniBadge`, `AppStoreIconView`) and the
  `AltSource.appsCount` helper moved, unchanged apart from `private` → internal, into
  `VexSign/Views/TabView/AppStoreRepositoryRows.swift`. `AppStoreView.swift` is now **1,387 lines**
  (from 1,567); no behaviour change, no renamed symbol.

**Still open, in the order it should happen** (each one mechanical, each one its own commit):
`AppStoreView` → `AppStoreHeroSection` (hero + shelves), `AppStoreSearch`, `AppStoreRepositories`;
`DownloadManager` (1,015 lines) → `DownloadPersistence`, `DownloadNotifications`, `DownloadImporter`
(the notification block is entangled with live activities and keep-alive state, so it needs the state
moved first — not a copy-paste); `VexSignApp` (803) → `AppDelegate`, `BackgroundTasks`, `DeepLinks`.
`StorageProtocol` and `SigningServiceProtocol` are next for the seam; `DownloadManagerProtocol` is
replaced by the narrower `PackageDownloading` on purpose — a protocol that mirrors a 1,000-line class
buys nothing.

Honest note on acceptance criterion 1 (~800 lines): `AppStoreView` is at 1,387, so the target is not
met yet. Splitting the remaining sections means changing who owns a dozen `@State`/`@FetchRequest`
properties, which cannot be validated without a compiler — that is the next PR, not this one.

### R15 · Swift 6 language mode, leaf first — **L**, P2

**Approach:** enable `SWIFT_STRICT_CONCURRENCY=complete` warnings-only on `NimbleKit`, then
`AltSourceKit`, then the app; fix by isolation, not by `@unchecked Sendable`. Adopt Swift 6 mode
per target once warning-free. Add `SWIFT_UPCOMING_FEATURE` flags gradually.

**Acceptance criteria:** no new `@unchecked Sendable`; the app target compiles with strict
concurrency warnings at zero for the touched files; CI enforces no increase.

**Status — gate landed, leaf adoption staged (2026-11-01).**

- **The count, measured:** the whole app has **3** concurrency escapes, all `@unchecked Sendable`
  (`Download`, `UnifiedTaskCenter`, `AppFileHandler`) — none `nonisolated(unsafe)`, none
  `@preconcurrency`. That is far better than the audit assumed, and it means the "no new
  `@unchecked Sendable`" criterion is cheap to hold.
- `tools/concurrency-discipline.py` freezes those three per file against
  `tools/concurrency-baseline.json`, wired into `ci.yml` (quick job) ("Concurrency discipline"). It is a
  counting gate by design: it runs where there is no compiler, and it does not pretend to prove
  isolation.
- `make strict-concurrency` is the real check: builds `AltSourceKit` with
  `-strict-concurrency=complete` (warnings, not errors) and `NimbleKit` in Swift 6 language mode
  (tools-version 6.0 ⇒ complete by default), then prints the remaining diagnostics. It exists so the
  leaf-first flip can be measured on a machine with a toolchain instead of guessed at.

**Deliberately not flipped yet:** `SWIFT_STRICT_CONCURRENCY=complete` on the app target is *not*
enabled. `ci.yml` (build job) defaults to `BUILD_WARNINGS_AS_ERRORS=true`, so turning it on from a
sandbox with no compiler would either be a no-op claim or break `main` for everyone. The order is:
run `make strict-concurrency`, fix the leaf warnings, enable `StrictConcurrency` in
`AltSourceKit/Package.swift` (a one-line `swiftSettings:` addition), then the app target.

### R17 · Localisation gate + catalogue sync — **M**, P2

**Fact:** 2,110 distinct literals vs 1,428 catalogue keys (799 missing, 490 English-only).
*Measured again before R17: 2,281 literals vs 1,420 keys — 989 missing.*

**Approach:** a script (`tools/sync-strings.py`) that adds missing keys with the English value;
a CI check that fails when source literals are absent from the catalogue (additions allowed, so
it never blocks a feature, only the drift). Pseudo-locale run in the simulator to catch
truncation. Do not machine-translate; leave new keys English and mark them for translation.

**Status:** implemented in this PR. Not compiled here; the script's own output is the evidence.

- `tools/sync-strings.py` scans every `.swift` file under `VexSign/` for `"…".localized(…)` /
  `String.localized("…")` calls and compares the literals with `Localizable.xcstrings`.
  `--check` exits 1 and lists the missing keys with the file that asks for them; `--write` adds
  them as `extractionState: manual` with the English literal as the `en` value. Nothing is
  machine-translated, and interpolated literals (`"… \(value)"`) are reported separately and never
  added — their runtime value is not a stable key.
- The catalogue was synced: **370 files scanned, 2 281 distinct literals, 1 420 → 2 409 keys**
  (+989). The file is edited textually, so the diff is additive instead of a JSON round-trip that
  would reformat all 1 420 existing keys; the merge refuses to write unless the result parses and
  keeps every existing entry.
- CI: `.github/workflows/ci.yml` runs `python3 tools/sync-strings.py --check` after the
  syntax/resource check, and re-runs when the script or any `.xcstrings` file changes.
- Verified here: `--check` exits 0 on the synced tree, and exits 1 naming the file when a literal
  is injected that has no key (`"A key that is deliberately missing"` → `VexSign/.../ZsignEngine.swift`),
  then 0 again once removed.
- **Not done:** the pseudo-locale simulator run (needs a simulator to catch truncation), and
  translations themselves — the catalogue now carries English for every key, which is the state
  Xcode presents to a translator.

### R18 · Accessibility pass — **M**, P2

**Fact:** 108 fixed font sizes, 24 labels, 0 identifiers, 0 Dynamic Type handling.
*Measured again before R18: 110 fixed sizes, 28 labels, 0 identifiers.*

**Approach:** replace fixed sizes with semantic styles where layout allows; add labels to icon-only
controls (sign, install, cancel, expiry pills); add `accessibilityIdentifier`s on the signing and
install flows for future UI tests; respect Reduce Motion in the animated surfaces
(`WebThemeMotion`, tab transitions); verify VoiceOver on sign → install → cancel.

**Status:** partially implemented in this PR. Not compiled here; no VoiceOver or simulator pass.

- **Identifiers.** `VexSign/Utilities/AccessibilityIdentifiers.swift` holds every identifier the
  signing and install flows expose (`AX.Signing.*`, `AX.Install.*`, `AX.Library.*`), and they are
  attached where the flows actually run: start/stop/progress/console in `SigningView`, the install
  pill in a library row, the install progress view, and the three library badges a row can show.
  Before this, the app had **0** identifiers; it now has 9, all prefixed and all covered by
  `VexSignTests/AccessibilityIdentifiersTests.swift` (unique, prefixed, dotted, and no identifier
  in `AX.all` that no flow expects).
- **Labels.** The lock badge in a library row is the one icon-only control in these flows that said
  nothing to VoiceOver; it now reads "Locked". The update and installed badges already had labels,
  and the install/sign pills carry their text with them.
- **Reduce Motion.** `WebThemeMotion` already honoured it (verified, left alone). Two animated
  surfaces did not: the pulsing icon in `InstallProgressView` and the refresh spinner in
  `UpdateMatchingSettingsView` — both now stand still when Reduce Motion is on, instead of repeating
  forever under a user who asked them not to.
- **Not done:** the fixed-size font migration. 110 `.font(.system(size:))` sites remain, most of
  them icons, badges and pill padding where an explicit size is the layout; converting the text
  sites to semantic styles changes line heights and row heights, which cannot be checked without a
  running app. That belongs to a pass with a simulator beside it, and is recorded here rather than
  guessed at. The VoiceOver walkthrough (sign → install → cancel) and truncation checks in other
  languages also need that environment.

**Tests:** new `VexSignTests/AccessibilityIdentifiersTests.swift` (4 cases): prefix, uniqueness,
shape, and coverage of the signing/install/library flows.

### R19 · Error-handling and logging discipline — **M**, P3

**Approach:** replace silent `try?` at user-visible boundaries with logged, typed failures
(start with `FileManager` writes, plist/entitlement writes, Keychain writes, backup/restore);
add a lint/config rule that new `try?` in these files requires a comment; unify
`FileLogger` + `SigningLog` + `os.Logger` behind one sink with categories and a redaction test.

**Status:** implemented in this PR, scoped to the three things that can be verified by reading and
by unit test. Not compiled here; tests not run.

- **One sink, redacted.** `FileLogger` is already the single place that writes the exportable log
  (`Documents/Logs/vexsign.log`, exposed over USB and the Web Manager) and mirrors to OSLog, so the
  redaction lives there: `VexSign/Utilities/Logging/LogRedaction.swift` masks `password=…`,
  `p12Password: …`, `token=…`, `api-key=…`, `Authorization:`/`Bearer …`, and the password inside a
  URL's userinfo. `SigningLog._append` redacts the same way, so the console shows exactly what the
  file holds. The rules are narrow on purpose — a rule that fires on ordinary text hides the reason
  a sign failed — and each one is asserted to fire *and* to leave normal lines alone.
- **Silence at the boundaries, fixed.** Four `try?` sites where a failure was invisible and
  user-visible:
  - `EntitlementsManager._write` — a failed entitlement save closed the sheet and left no file;
    now serialisation, directory creation and the write are one `do/catch` that logs.
  - `IPAChangeJournal` — the byte-level fallback returned a backup name even when the copy failed,
    promising an undo it could not deliver; it now logs and returns `nil`.
  - `TweakAnalyzer` — an archive member that could not be written silently under-read the package
    (no control file, wrong dylib count); each failure is logged now.
  - `BackupCrypto.isEncrypted(_ url:)` — an unreadable file answered "not encrypted", which sends
    the user down the plaintext restore path; the answer stays `false` and the reason is logged.
  - Keychain writes were checked and needed nothing: every `SecItem*` call already inspects its
    `OSStatus` instead of discarding it.
- **A gate against drift.** `tools/error-discipline.py` counts unjustified `try?` per file against
  `tools/error-discipline-baseline.json` (**407 in 113 files** at the time of writing) and fails when
  a file grows past it. A deliberate silent failure is allowed, but only by saying why on the line:
  `try? cache.remove(at: url) // try? ok: best effort`. `--write` regenerates the baseline, so
  lowering a number is a visible, reviewable edit. CI runs it after the localisation check.
- **Not done:** the full `FileLogger` / `SigningLog` / `os.Logger` merge. They now share one redacted
  path, but `SigningLog` still owns the console's batching and `Logger.misc/security/signing` are
  still used directly at call sites; collapsing them into one `Log` façade is a rename with no
  behavioural gain, and it would touch ~200 call sites. Recorded here rather than implied.

**Tests:** new `VexSignTests/LogRedactionTests.swift` (11 cases): every rule fires on the secret it
targets, ordinary log lines and keyword-containing words are untouched, a URL keeps its host while
losing its credentials, redaction is idempotent, every occurrence on a line is masked, and empty
input stays empty.

### R20 · Get repository decoding off the main thread — **S/M**, P2

**Fact:** F16. `SourcesViewModel` decodes after the task group (`:270-300`).

**Approach:** decode inside the group task, return a `Sendable` result, publish on the main actor;
add a signpost around fetch/decode/publish and a test with a synthetic 5 MB feed asserting the
decode is not on the main thread.

**Status:** implemented in this PR. Not compiled here; tests not run.

- **Confirmed first.** `fetchSources` is `@MainActor` (`SourcesViewModel.swift:95`) and decoded every
  payload *after* the task group returned, so a large repository was parsed on the thread that draws
  the screen — F16, and why a big source made the store stutter.
- **What changed.** `VexSign/Utilities/SourceFeedLoader.swift` owns fetch *and* decode in a value
  type that carries no isolation. `load(url:headers:identifier:)` awaits the injected fetcher, then
  decodes, and returns a `SourceFeedResult` whose outcome is `Sendable` (`ASRepository` already was:
  `AltSourceKit/…/ASRepository.swift:17`). `fetchSources` now collects those finished results and
  applies their side effects on the main actor — snapshot cache, health records, stale marking,
  publishing — with the dictionary keyed by identifier so a duplicate cannot trap.
- **Snapshots too.** The offline prefill decoded every cached snapshot inside the same `@MainActor`
  method; those reads now run on a utility executor (`_cachedRepositories(for:)`) and only the
  decoded models come back. Both decode sites of F16 are gone.
- **Signposts.** `SourceFeedSignposts` brackets three phases — `source` (fetch + decode per source),
  `decode`, and `publish` — so a slow refresh is attributable in Instruments instead of guessed at.
- **Testability.** The fetcher is an injected `@Sendable` closure, and `willDecode` reports
  `Thread.isMainThread` immediately before decoding. That hook is what turns "the decode is not on
  the main thread" into a measurement — the test starts the load from the main actor, the way
  `fetchSources` does, and asserts the hook saw `false`.

**Tests:** new `VexSignTests/SourceFeedLoaderTests.swift` (7 cases): a synthesised ~5 MB feed decoded
off the main thread (started from the main actor, hook records `false`) with the payload preserved
for the snapshot cache; a valid feed decoding with its payload intact; invalid JSON kept as
`invalid`; an empty body as a failure; HTTP 429 flagged rate-limited; another HTTP error not
flagged; and the rate-limit classifier's edges.

### R21 · Enforce download integrity where the source provides it — **S**, P3

**Fact:** F20. `ASRepository` carries `size` per app/version; downloads compute a SHA-256 but do
not enforce it.

**Approach:** when a source declares `size`, reject a mismatching download before import with an
actionable error; when a hash is known (manual URL with a hash, or a future source field), block
import on mismatch. Keep "ignore once" explicit.

**Status — done (2026-11-01).**

The check happens once, in `DownloadManager.handlePackageFile`, before anything is handed to `FR`:

- `DownloadIntegrity` (`VexSign/Utilities/DownloadIntegrity.swift`) is pure and testable: an
  `Expectation` (`byteCount`, `sha256`, normalised on the way in), a `Verdict`
  (`.unverified` / `.verified(checks:)` / `.mismatch([Failure])`) and `describe(_:fileName:)`,
  which prints the byte counts in full so the message can be compared with the source's own
  listing. No `Error`/`NSError` matching is involved — the verdict is an explicit enum.
- `Download` carries `integrity` (mutable, so a resumed row can take a promise a later fetch
  learned) and `retainedPackageURL` — the staged file, kept because the normal import path clears
  `pendingFileURL` and the one override still has to import something.
- `startDownload` takes `integrity:` with a default of `nil`, so every existing call site (manual
  URL, App Intents, discovery, update paths, `startArchive`) compiles and behaves as before, and
  an empty expectation short-circuits straight to the old import path. The source-app download
  button (5 sites) now passes `app.downloadIntegrityExpectation`, built from `App.size` with the
  version's own `size` as fallback.
- On a mismatch: the failures are logged (`category: "download"`), `finishImport(succeeded: false)`
  runs — a failed check is a failed import, so the **row goes away exactly as it does for any other
  failure** — and the alert that reports the mismatch carries the choice: **Import Anyway** or
  **Delete**. That placement is deliberate. The first version put a button on the download row and
  was wrong twice over: `finishImport` removes the row, so the button could never be reached, and the
  rejected file was left on disk. The alert is the only surface that outlives the row, and it forces
  an answer instead of leaving a rejected package where something else could pick it up later.
  `DownloadManager.importAnyway(_:failures:)` logs the bypass with the full reason and applies to
  that file only; the expectation is *not* cleared, so re-downloading is checked again. **Delete**
  removes the file unconditionally — not through `CleanupManager`, whose
  "delete downloaded IPA" preference must not decide whether a file the user just refused survives.
  In the background there is nobody to ask, so the file is discarded and the notification says why.
- Size and hash are both read off the main thread (a `.utility` queue) and the import only starts
  once the verdict is in, so a 2 GB IPA does not freeze the row and a truncated one never reaches
  the unarchiver.

Honest limits, recorded rather than implied: there is **no UI that collects a hash yet** — hash
enforcement is implemented and tested at the pipeline level, and a future source field or a manual
"URL + SHA-256" entry only has to set `Expectation.sha256`. Paths that import a file obtained
elsewhere (WebManagerServer upload, `SelfUpdateManager`, `UpdateAllManager`) never go through
`startDownload` and are therefore not covered by a source's declaration; the web upload path is
unauthenticated local input and stays out of scope here.

`DownloadManager.ErrorDelegate` gained a second requirement with a default implementation, so a
conformer that only knows the plain message still compiles — and falls back to *deleting* the file,
never to importing it unasked.

`VexSignTests/DownloadIntegrityTests.swift` — 9 cases over real temporary files: empty expectation
⇒ unverified; size match; size+hash match ⇒ two checks; `SHA256:`-prefixed upper-case hash
normalised before comparing; truncated file ⇒ both numbers in the message; missing file ⇒
"could not be read"; hash mismatch with a matching size; both failing at once (two lines, one
closing hint); `byteCount` on a real file and on a missing one.

Not done, deliberately: no new settings, no per-source "trust" toggle, no hash prompt in the
manual download sheet (that is a UI decision, not an integrity one).

### R22 · Anti-revoke/DNS hardening — **S**, P3

**Fact:** F19. `NovaDNSDynamic` uses `dns.novadev.vip` + `api.novadev.vip`.

**Approach:** make the endpoint configurable, display it, keep the feature off by default, log when
it rewrites resolution, and state plainly that it cannot guarantee anything about revocation. No
new third-party dependencies behind security toggles.

**Status — done (2026-11-01).**

`VexSign/Utilities/NovaDNSDynamic.swift` no longer contains an endpoint the app is stuck with:

- `defaultRulesURL` (`https://api.novadev.vip/api/novadns-dynamic/rules.json`) is now a *default*.
  `setCustomRulesURL(_:)` stores an override in `UserDefaults` (`VexSign.novaDNSRulesURL`), accepts
  only absolute `https://` URLs with a host, trims whitespace, returns `false` and changes nothing
  otherwise, and clears the override when given an empty string. A stored value that no longer
  parses falls back to the default instead of leaving the feature silently dead.
- `actionURL(_:)` derives the API base from the rule list's folder, so overriding the rules
  endpoint moves the `enablePPQ` call with it — one setting, not two. Tests pin both the default
  (`…/api/novadns-dynamic/enablePPQ`) and an override (`https://rules.example.com/nova/enablePPQ`).
- Settings → Installation → Anti-Revoke now **shows** the effective endpoint, offers a text field to
  replace it, a "Use This Endpoint" button and a Reset, and logs saving, resetting, rejecting a bad
  URL, enabling and disabling the toggle (`category: "antirevoke"`).
- `AppInstaller` logs once per install, before the first PPQ request, that resolution is being
  rewritten and through which endpoint. The 10-second heartbeat during install stays quiet — a log
  line every ten seconds would bury the one that matters.
- Every network path in the type now reports failure instead of swallowing it (`sendRequest` logs
  non-2xx and transport errors, `fetchRules` logs non-200 and decode/transport errors, the rules
  cache logs an encode failure); three silent `try?` in this file became `do/catch`. The one that
  remains is the cache read, justified inline: a corrupt cache is the same as no cache.
- Off by default is unchanged and now asserted: `@AppStorage("VexSign.useNovaDNSDynamic")` defaults
  to `false`, `AppInstaller` reads `UserDefaults.bool` (absent ⇒ `false`), and a test pins that.

The footer says what the feature cannot do, in the app rather than only in this document: it is a
third-party server acting on the device's behalf, VexSign cannot guarantee what it does with the
queries, and nothing here restores or protects a certificate Apple has already revoked.

No new dependencies: Foundation, `URLSession`, `UserDefaults` and the existing logger only.

`VexSignTests/NovaDNSDynamicTests.swift` — 11 cases: unset override ⇒ default; https override
trimmed and stored; plain `http://` rejected; non-URL and bare `https://` rejected; empty clears;
action URL beside the rule list; action URL follows an override; cached-rules round trip; no cache
⇒ default rules; feature off unless a user turns it on (plus the shared fixture cleanup).

Not done, deliberately: no attempt to verify the third-party service's behaviour, no automatic
fallback between services, and no probe of whether a resolver actually sinkholes the listed hosts —
VexSign cannot test someone else's DNS from the device, and pretending otherwise would be the same
"protection" the audit objected to.

---

## Phase 5 — Deliberate differentiators (after the above is green)

### R23 · Consolidated "inject by default" tweak screen — **S**, P3
The model exists (`TweakModels.swift:222-274`); only the UI is missing. One list, one toggle per
tweak, bulk select, search. Pattern from MySign (GPL-3.0), implemented against VexSign's manager.

**Status — done (2026-11-01).** `VexSign/Views/Tweaks/TweakInjectionDefaultsView.swift`, reached from
the Tweak Manager's overflow menu ("Inject by Default"). One row per tweak, one toggle per row, search
over name and notes, All On / All Off for whatever the search shows, and a live "N of M" count. Every
toggle writes the same `injectByDefault` the tweak's own screen writes, through
`TweakManager.update(_:)` — no second source of truth, nothing new persisted. Disabled tweaks are
listed but not toggleable, and a tweak with exceptions says so ("Except 2 app(s)") because that is
the thing a user gets wrong when switching things on in bulk. The list logic
(`TweakInjectionDefaults.matches` / `.apply`) is a separate pure type;
`VexSignTests/TweakInjectionDefaultsTests.swift` covers search folding, bulk apply skipping disabled
tweaks, search-scoped apply, idempotence, exceptions surviving, and both directions of the
`autoInjects(into:)` rule. No MySign code was used — the pattern is a list with toggles.

### R24 · On-device signed OCSP verification — **M**, P2/P3
Replace what R3 removed with real evidence: build an OCSP request (SHA-1 CertID from
issuer name/key hashes + serial), parse the BasicResponse, **verify the responder signature**
against the issuer/Apple WWDR chain, check `thisUpdate`/`nextUpdate`, and report
Valid / Revoked(date, reason) / Unknown with the raw evidence available in diagnostics. Pure DER
code, no networking in the parser, fixtures generated offline. Behavioural reference: Odysseus
(GPL-3.0) `ODOCSPCore`/`ODX509`; implementation must be VexSign's own. Wire policy: warn / block /
allow on revoked, notifications on change.

**Status — core done, one deliberate gap (2026-11-01).**

- `Utilities/OCSP/ASN1.swift`: a content-shaped DER reader/writer (the existing
  `Utilities/Signing/DER.swift` is offset-shaped, for walking a CMS blob without copying). Lengths
  are bounds-checked, indefinite lengths refused, high-tag-number form unused.
- `Utilities/OCSP/OCSP.swift`: `OCSPCertID` (SHA-1 name/key hashes, serial), `OCSPRequestBuilder`
  (one CertID, SHA-1, **no nonce** — Apple ignores nonces, and a dropped nonce that looks like
  replay protection is worse than none), `OCSPResponseParser` (responseStatus, BasicOCSPResponse,
  `producedAt`, every SingleResponse with status/times, the exact `tbsResponseData` bytes, the
  signature algorithm OID and the signature), and `RevocationPolicy.decide(...)`, which returns
  `RevocationDecision(status:isFresh:action:)` with `shouldBlock` requiring a revocation **and** a
  fresh answer — a stale "revoked" warns, it does not destroy an install.
- 22 tests in `VexSignTests/OCSPTests.swift`, fixtures built with the same writer and parsed back:
  TLV and long-form round trips, minimal integers with the high bit kept clear, context tags,
  GeneralizedTime, truncated input refused, request structure and hashes, good/revoked/unknown
  parsing, revoked time **and** reason, signature + signed bytes kept for the verifier,
  unsuccessful responseStatus reported rather than guessed, garbage refused, serial matching that
  ignores leading zeros, and the whole policy matrix (block on fresh revocation, warn only under
  warn, never block on stale, 24-hour rule when `nextUpdate` is absent, an answer about another
  certificate not used).

**Signature verification, second slice (same day).** `Utilities/OCSP/OCSPResponderVerification.swift`:

- The parser now also carries `responderID` (`.byName(DER)` / `.byKey(SHA-1 of the public key)`) and
  every certificate from `certs`, re-encoded as DER.
- `SecurityOCSPResponderVerifier` performs the actual check with `SecKeyVerifySignature`, mapping the
  four algorithms a responder realistically uses (RSA-SHA256, RSA-SHA1, ECDSA-SHA256,
  ECDSA-SHA384) and naming the OID bytes when it meets something else.
- `OCSPValidator` decides *which* certificate to try — the one the response named by key first,
  then the rest in listed order — and enforces the property that matters: **no decision is produced
  until a responder certificate has signed the bytes**. A rewritten response cannot say "revoked"
  either; both directions are discarded.
- `OCSPCertificateKey` walks certificate → tbsCertificate → SubjectPublicKeyInfo → BIT STRING to
  compute the key hash, so the by-key match is real rather than assumed.

16 more tests in `VexSignTests/OCSPResponderVerificationTests.swift`, all with a fake verifier so the
plumbing is held to something: the key walk and key hash, the by-key certificate tried first, order
preserved without a key ID, every candidate tried, no embedded certificate, an unsupported algorithm
reported by name rather than as a bad signature, a missing signature rejected before any certificate
is touched, an answer about another certificate rejected before verification, an unsuccessful status,
a verified good answer producing a decision, a fresh verified revocation blocking, and
**an unverified revocation producing no decision at all**.

**Still not done, said plainly:** the responder certificate is not yet chained to the issuer or to
Apple's WWDR root. A signature proves who signed, not who vouches for the signer — that is `SecTrust`
work against a real certificate store and a captured live response. And nothing calls this yet: no
request is built, no UI shows the verdict, no warn/block/allow setting exists. The remaining steps
are `OCSPResponderVerifier` → `SecTrust` chain check → the setting and the evidence view. Until then
this is a tested library, not a feature, and it changes no behaviour.

### R25 · Repository trust and provenance — **M**, P3 (candidate)
VexSign documents that "trusted repository" badges are user-controlled and not cryptographic.
Next step: optional Ed25519-signed catalog support (`source.json` signature + advertised key),
verified before refresh, with the badge derived from the signature instead of a toggle. This is a
genuine differentiator no fork offers. Also document the ESign decryption-key provenance in
`AltSourceKit` (`ASDecrypt`, `EsignSourceKey`) in `LICENSE`/docs.

**Status — verifier, policy, badge and docs landed (2026-11-01).**

- `Utilities/SourceProvenance.swift`: a source may carry a top-level `vexsign` member
  (`algorithm: "ed25519"`, base64 `publicKey` 32 bytes, base64 `signature` 64 bytes, optional
  `publisher`). The signature covers the **canonical** form — the `vexsign` member removed, the rest
  re-serialised with sorted keys and no whitespace — verified with CryptoKit's
  `Curve25519.Signing.PublicKey`, no new dependency.
- Policy, and the reason for it: **unsigned is accepted** (that is every repository in existence
  today, and the badge stays absent); **a claimed signature that does not verify is refused** —
  the refresh fails with the specific reason and the previous catalog stays. Falling back to "trust
  it anyway" would make the signature decorative.
- `SourceFeedLoader.load` checks before publishing, logs rejections, and records the verdict in
  `SourceProvenanceStore`; the repository row now shows **Signed by …** (teal) or **Bad signature**
  (red) next to the existing user-controlled "Trusted" badge. Two different things, two different
  labels: one is the user's opinion, the other is evidence from the last refresh.
- 12 tests in `VexSignTests/SourceProvenanceTests.swift` sign with a real Ed25519 key rather than
  stubbing the verifier: unsigned accepted, signed verifies, publisher-less signed verifies,
  **tampered document rejected**, signature from another key rejected, unknown algorithm named in
  the reason, wrong-sized key and signature rejected, canonicalisation ignoring key order and the
  signature member, and the store's round trip including clearing.
- `docs/SOURCE_SIGNING.md` documents the format, the canonicalisation rule, an OpenSSL 3 recipe for
  producing a signature, the accept/refuse table, and the limits: the key is **not pinned**, so this
  defends against a modified document in transit, not against a hostile host. The ESign
  decryption-key provenance (`ASDecrypt`, `EsignSourceKey`) is written down there too — those keys
  are published by the repository and authenticate nothing.

Not done: no key pinning (a repository's key can change with its URL), no UI to manage keys, and the
signature is not shown in the repository detail screen — only the row badge.

### R26 · Install-method polish — **S**, P3
One place that explains and chooses: local HTTPS (default), idevice with pairing, export/share,
and — when TrollStore is detected — "Open in TrollStore" (deep link only; no CoreTrust
reimplementation). Include a preflight that names the missing prerequisite for each method
(pairing file, certificate trust profile, reachable host) instead of failing later.

**Status — preflight landed (2026-11-01).** `VexSign/Views/Settings/Installation/InstallPreflight.swift`
evaluates four routes — local HTTPS server, idevice, export/share, TrollStore — into
`ready` / `missing(what to do)` / `unavailable(why)` / `unknown`, and `InstallationView` renders them
under the existing picker as "Install methods", each with a status word (never colour alone), the
missing prerequisite spelled out, and a checkmark on the selected route. Inputs are real: a
`LocalTLSIdentity.current()` certificate, `HeartbeatManager.pairingFile()` on disk, and
`canOpenURL` against `apple-magnifier://` / `trollstore://` (both declared in
`LSApplicationQueriesSchemes`, added here). The TrollStore row says what VexSign does not do — it
never installs TrollStore and does not reimplement CoreTrust. 9 tests in
`VexSignTests/InstallPreflightTests.swift` cover the whole matrix and the presentation strings;
the evaluation is pure, so they need no device.

Deliberately not done: the export row does not toggle `VexSign.useShareSheetForArchiving` (the
setting lives in its own screen; duplicating it here would be a second control for one flag), and
TrollStore is detected but not offered as a deep link — a link needs an IPA URL, which this screen
does not have.

### R27 · Cloud signing — revisit only with a real signer — **parked**
`cloud-signing/` is orchestration without a signer; a native client without a service is a dead
end. Revisit if and when a signing sandbox and a threat model exist. Do not add UI for it before
then.

Until that decision is made the client refuses to transmit a private key: `CloudSigningClient`
throws `CloudSigningError.privateKeyUploadDisabled` from `signRemotely` and from any
`upload(kind: .p12)`, so a future feature has to be built deliberately rather than switched on
(R3 set that invariant, and `CertificateRevocationTests` asserts it).

---

## Sequencing

| Release gate | Contents | Why this order |
| --- | --- | --- |
| **Gate A** (security + guardrails) | R10, R1, R2, R3, R11, R4 | Secrets stop leaving the device; the library stops being written off-main; CI can prove it |
| **Gate B** (signing correctness) | R6, R7, R13 (adapter), R12 | Every sign is verified and understandable; the pipeline gains a cancel path |
| **Gate C** (lifecycle) | R5, R16, R9 | Installs are confirmed; the engine moves only after verification exists |
| **Gate D** (capability) | R8, R24 | Per-extension signing and real revocation evidence |
| **Gate E** (maintainability) | R14, R15, R17, R18, R19, R20, R21, R22 | Debt paid while the surface is stable |
| **Gate F** (differentiators) | R23, R25, R26 | Nice-to-haves that no fork matches |

**Where the gates stand (2026-11-01).** A ✅ · B ✅ · C ✅ · **D — R24 has its OCSP request/parse/
verify/policy core and 36 tests, but the responder certificate is not chained to an issuer yet and
nothing calls it; R8's second half is blocked by the pinned engine (one `ZSignAsset` per
`SignFolder`)** · **E — all seven landed; the follow-ups are recorded, not finished**: R14's
remaining extractions (`AppStoreView` 1,386 → ~800), R15's app-target flip (needs
`warnings-as-errors` off for a first measurement), R24's `SecTrust` step, and R27 parked · F ✅.

Everything above is verified only by the checks that run without a compiler
(`make verify`: quick check, catalogue, `try?`, singleton and concurrency gates) and by the static
review described in `docs/TEST_PLAN.md`. No claim in this document rests on a build that has not
happened.

Each gate ends with: green CI (build + unit tests + platform + server + ecosystem), an updated
`docs/FEATURE_STATUS.md` row per feature, a changelog entry, and — where the change touches
signing or installation — a device-pass checklist recorded in the PR.

---

## Definition of done (per task)

1. Scope in the PR matches the task; no drive-by refactors.
2. New logic is unit-tested; the test is named for the behaviour, not the implementation.
3. `xcodebuild test` green (R10 prerequisite), build-check green with warnings-as-errors
   baseline unchanged or smaller.
4. Failure paths produce a user-visible, actionable message — not `try?`.
5. Strings added to `Localizable.xcstrings` (R17 gate once it exists).
6. `docs/FEATURE_STATUS.md` updated with setting → persisted value → consumer → status.
7. Licence/attribution recorded in the commit trailer when an idea or code came from a reference
   project (GPL family only; never AGPL).
8. Device pass listed explicitly (or "not required — pure logic/CI-only").

---

## Explicitly not doing (recorded so it stays a decision)

| Item | Why not |
| --- | --- |
| Apple ID login / on-device certificate provisioning (Odysseus/SideStore) | SideSign is AGPL-3.0; credential handling and ToS exposure; changes the product's trust model |
| LiveContainer container runtime / TweakLoader | AGPL-3.0; would make VexSign an app runtime |
| AltServer/AltDaemon/minimuxer architecture | AGPL-3.0; desktop/daemon model, already served by IDeviceKit |
| TrollStore CoreTrust installation | Per-iOS-version exploit; infeasible in a sandboxed signer. Deep link only |
| Copying AGPL code "just a little" | Would force the whole distribution to AGPL; every item above is re-implemented or rejected |
| Rewriting signing/storage/sources | They work; the audit's failures are boundary bugs, not design dead ends |
| Global popularity rankings / telemetry | Not needed for the product; the current local-ranking stance is honest |
| Machine-translating the catalogue | Worse than English fallback; translate deliberately |

---

## Suggested first PR (small, high value)

`R10` alone: add the unit-test workflow and fix whatever it reveals. It changes no product
behaviour, gives every later task a regression oracle, and immediately turns 78 existing tests
from documentation into enforcement.

Suggested commit subject after that:

```
ci(tests): run the VexSignTests scheme on every PR

Adds a macOS job that builds and runs the VexSignTests scheme on a
simulator (CODE_SIGNING_ALLOWED=NO, parallel testing off so the
process-wide state several tests touch stays deterministic), caches
SwiftPM with the same key as build-check, annotates failures with
xcodebuild_report.py and uploads the xcresult bundle and raw log.
The destination comes from .github/scripts/select_simulator.py instead
of a pinned device name, which is what makes this kind of job rot.
Adds `make test` (SIMULATOR=auto by default) so the same command runs
locally, and documents the job in CONTRIBUTING.md.
```
