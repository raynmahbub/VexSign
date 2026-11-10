# Major-bug investigation: signing, installation, security, concurrency and CI

This is the second report in the assignment. The first,
[`signing-and-installation-lifecycle.md`](signing-and-installation-lifecycle.md), covers the three
reported screenshot issues (signing workflow showing "Not run", the library showing "Not installed"
during an install, and the install sheet spinning). This one covers the ten-area mandatory
investigation that followed it.

Every area was read at the implementation and at its call sites before being classified. Nothing
here is a guess about code that was not opened, and no area is marked clean because it looked
large or well-commented.

**Result: 4 confirmed bugs and 1 confirmed coverage gap, all fixed. 5 areas verified sound or
fail-closed by design, with the evidence recorded so the conclusion can be re-checked.**

| # | Area | Classification | Outcome |
|---|------|----------------|---------|
| 1 | Native Apple signing + production CMS | Architectural risk — deliberately incomplete, fail-closed | No fix; wiring it would be speculative feature work |
| 2 | Private API dependencies + fallbacks | **Confirmed bug** | Fixed: crash on missing selector, and invisible failure |
| 3 | Certificate / private-key matching | Latent hazard — fail-open | Fixed fail-closed |
| 4 | Nested app/framework/extension signing | **Confirmed gap** | Fixed: verifier was blind to `Watch/` |
| 5 | Concurrent signing, downloads, installation | Sound | No fix |
| 6 | Cancellation, stale callbacks, recovery | Sound | No fix |
| 7 | ZIP extraction, duplicate entries, races | **Confirmed gap** | Fixed at the shared validator |
| 8 | Cloud signing auth / job isolation | No bug found | No fix |
| 9 | Guest-host packaging reliability | No bug found | No fix |
| 10 | Native Swift tests in regular CI | **Confirmed bug** | Fixed: 3 compiled app files were outside every trigger |

---

## Area 10 — native tests did not run for the app code they compile

**Classification: confirmed bug.** Priority CI/regression testing (P1), but it is the reason the
other nine areas are harder to trust, so it was fixed first.

### Root cause

`NativeSigning/prepare_smoke.py` builds a SwiftPM package whose `NativeSigningLinkSmoke` target
compiles six files copied **byte-for-byte out of the app target**:

```
VexSign/Backend/Services/AppleAccountAuthenticationState.swift
VexSign/Backend/Services/AppleAccountSessionCoordinator.swift
VexSign/Backend/Services/AppleAccountSessionRepository.swift
VexSign/Security/AppleAccountCredentialStore.swift
VexSign/Security/AppleAccountResumeJournalStore.swift
VexSign/Security/AppleAccountStorageRuntimePolicy.swift
```

`swift test --package-path .build/native-signing-smoke` runs in `embedded-container.yml`, and
`NativeSigning/Tests/NativeAccountBackendTests.swift` exercises those files. But the workflow's
`push`/`pull_request` path filters listed `VexSign/Security/AppleAccount*.swift` and **not**
`VexSign/Backend/Services/AppleAccount*.swift`.

Matching the copied list against the filters with `fnmatch` gave three files covered and three not
covered. So a pull request touching only `AppleAccountSessionCoordinator.swift` ran `ci.yml`
(whose `VexSign/**` filter runs no native test at all) and skipped the one job that compiles the
file it changed. The structural cause is that the copied-file list lives in Python and the trigger
list lives in YAML, with nothing tying them together.

`ci.yml` was also confirmed to never compile or test `NativeSigning`'s 34 test files: its `tests`
job runs `-scheme VexSignTests` only.

### Fix

* `.github/workflows/embedded-container.yml` — added `VexSign/Backend/Services/AppleAccount*.swift`
  to both the `push` and `pull_request` filters.
* `tools/test_workflow_policy.py` — two tests. The first **derives** the copied-app-file list from
  `prepare_smoke.py` by parsing it, checks each file exists, and asserts every one is matched by a
  `push` *and* a `pull_request` filter. Deriving it is the point: a third hand-written copy of the
  list would drift the same way the YAML did. The second asserts the 34-file test manifest and
  `NativeSigning/Tests/*.swift` are the same set in both directions, so a test file can neither be
  left out of the smoke package nor be named by it after deletion.

### Verified

Removing the new workflow filter makes the new test fail with six subtest failures naming
`AppleAccountSessionRepository.swift` and the others. Restoring it passes. `make verify` runs
`tools/test_workflow_policy.py`, so this is enforced locally as well as in CI.

Two related checks came out clean and are recorded so they are not re-derived: the test-file
manifest is complete (0 missing, 0 extra), and the filters' omission of `SideSign/Tests/**` is moot
because that directory does not exist and `SideSign/Package.swift` declares no test target.

---

## Area 2 — a missing private API crashed instead of degrading, and failure was invisible

**Classification: confirmed bug.** Priority security/compatibility (P0-adjacent: it terminates the
app).

### Root cause

Three files still touch private API. Two were already correct:

* `NimbleKit/.../NBVariableBlurView.swift` is public-API only (`UIVisualEffectView` with
  `.systemMaterial`, gradient-mask fallback to `effectView.mask = nil`) and is already pinned by
  `tools/test_public_blur_policy.py`.
* `VexSign/Utilities/MobileGestalt.swift` resolves `MGCopyAnswer` through `dlopen`/`dlsym`, closes
  the handle in `deinit`, and returns `nil` when the symbol is absent.

The third, `UIApplication+open_private.swift`, had two defects:

1. **`openApp(with:)` sent selectors without checking them.** It called
   `workspaceClass.perform(NSSelectorFromString(defaultSelector))` and
   `workspace.perform(openSelector, with:)` with no `class_getClassMethod` / `responds(to:)` guard.
   `perform(_:)` against a selector the class does not implement raises
   `doesNotRecognizeSelector:` and terminates the process. On an iOS build that filters
   `LSApplicationWorkspace`, pressing **Open** would crash the app. Its sibling
   `installProgress(for:makeSynchronous:)` in the same file already had exactly these guards, so
   the lesson had been learned once and not applied to the other function.
2. **It returned `Void`.** All five call sites could not distinguish "launched" from "this iOS
   version does not allow it". `LibraryCellView` deliberately shows an Open button for apps whose
   install state is *unknown* ("on an app it cannot speak for, it is still the only way in"), so on
   such a build the button was silently dead — the same class of invisible negative the install
   lifecycle work in the first report exists to remove.

### Fix

* `UIApplication.openApp(with:)` now returns `Bool` and is `@discardableResult`, so all five
  existing call sites compile unchanged. It guards `!identifier.isEmpty`, checks
  `class_getClassMethod` for `defaultWorkspace` and `responds(to:)` + `method(for:)` for
  `openApplicationWithBundleID:`, and dispatches that selector through its real calling convention
  (`@convention(c) (AnyObject, Selector, NSString) -> Void`) rather than `perform(_:with:)`, which
  would reinterpret the method's primitive `BOOL` return as an object pointer.
* **`VexSign/Utilities/AppLauncher.swift`** (new) is the adapter every user-facing launch goes
  through. It reports an empty identifier and an unavailable private API with `Toast.error`, so a
  `false` reaches a person instead of being dropped.
* `InstallCardView.swift`, `InstallQueueWindow.swift` (two sites) and `LibraryCellView.swift` now
  call `AppLauncher.open(_:)`. The one caller left on the primitive is
  `UIApplication+suspend.swift`'s `suspendAndReopen()`, which calls `exit(0)` half a second later —
  there is no user left to inform.

### There is no public fallback, and none was invented

iOS offers no public API that launches another app by bundle identifier, so the honest degradation
is a reported failure, not a substitute code path. `openApp` returning `true` means **the request
was dispatched**, never that the target app reached the foreground — iOS confirms nothing here, and
the doc comment says so explicitly rather than implying a guarantee that does not exist.

### Tests

* `VexSignTests/PrivateLaunchSurfaceTests.swift` (new, 2 tests): an empty identifier returns
  `false` without resolving any private class (deterministic — the guard runs first), and a launch
  request for a definitely-absent app returns at all. The second test deliberately asserts nothing
  about the returned value, because that depends on the iOS build the suite runs on; reaching the
  end of the method *is* the assertion, since the regression is a terminated test runner rather
  than a failure.
* `tools/test_private_launch_policy.py` (new, 6 tests): pins both selector guards, the `-> Bool`
  contract, `@discardableResult`, the `@convention(c)` dispatch, the adapter's two user-facing
  reports, that `installProgress` still degrades to `nil` rather than `0`, and that no shipping
  Swift file calls the primitive directly. Test files are excluded from that last rule — a test
  that calls the primitive is testing it, not shipping it.

### Verified

Deleting the `class_getClassMethod` guard makes the policy gate fail; restoring it passes. The gate
also caught its own author: the first run failed on `PrivateLaunchSurfaceTests.swift` until the
rule was scoped to product code.

---

## Area 7 — two extraction backends, one of which resolved conflicts by overwriting

**Classification: confirmed gap.** Priority security (P0).

### What was already correct

`ArchiveSafetyValidator` rejects absolute and `~` paths, NUL bytes, `.`/`..` components,
`:`-containing components, symlink entries, more than 50 000 entries and more than 8 GiB
uncompressed (with an accumulation guard that cannot underflow). `validateDestination` resolves the
base with `resolvingSymlinksInPath().standardizedFileURL`, walks every existing prefix rejecting
symlinks, compares **path components** rather than string prefixes (so `vexsign-work-other` is not
accepted as inside `vexsign-work`), then runs `StoragePreflight.check`.

`IPAExtractor` is the strict backend: it re-validates before **every** write, de-duplicates on the
resolved destination path, verifies both `written == uncompressedSize` and `checksum ==
entry.checksum`, rejects symlinks, applies directory attributes last in reverse order, pauses its
300 s deadline during `checkpoint()`, and checks `availableImportantCapacity` plus 16 MiB.

### Root cause of the gap

Duplicate detection lived **inside `IPAExtractor`**, not in the validator every backend shares.
`TweakExtractor._unzip` and `IPAWorkspace.unzip` both hand the same validated archive to
`Zip.unzipFile(..., overwrite: true, ...)` on a global queue. Because `validate` normalizes
components — it splits on `/` omitting empty subsequences and rejoins — `Payload/App.app/x` and
`Payload//App.app/x` are two distinct entries that both pass and both resolve to one destination.
With `overwrite: true` the later entry silently replaces the earlier one. That is a
conflicting-output-path hole on precisely the paths the IPA extractor had already closed, and it is
the shape of attack where a bundle is inspected as one file and written as another.

### Fix

Duplicate detection moved into `ArchiveSafetyValidator.validate`, so all four callers get it, with a
new `ValidationError.duplicateEntry(String)` case and a localized description. The comparison is
**case-insensitive** because the destination filesystem is: APFS on iOS treats `Info.plist` and
`info.plist` as one file, so entries differing only in case collide exactly like identical ones. A
directory entry and a file entry sharing a path collide too — the trailing separator is not part of
an entry's identity. An empty output path is rejected rather than claimed, so a rejected entry
cannot consume a destination.

A real IPA's explicit directory entries (`Payload/`, `Payload/Test.app/`, …) are unaffected: they
are distinct normalized paths, which the existing
`testRealIPAWithExplicitPayloadDirectoryEntries` fixture already covers.

### Recorded as an architectural risk, not fixed

`validate` → extract is not atomic. Destinations are fresh unique temporary directories
(`TweakExtractor` first copies the archive into its own `workDir` and removes both the copy and the
directory on any error; `IPAWorkspace` unzips into a freshly created directory), so turning the
window into an exploit needs a concurrent writer inside the app's own sandbox. Closing it properly
means re-validating per entry during extraction, which is `IPAExtractor`'s design and not something
to retrofit onto the `Zip`-based paths speculatively.

### Tests

Six tests added to `VexSignTests/ImportAndInstallationTests.swift`: two entries claiming one path;
duplicates differing only in case; a directory entry colliding with a file entry; distinct paths,
siblings and nested frameworks *not* colliding (a full realistic IPA entry list, asserting the
claimed-set size); an empty path rejected without consuming a destination; and the error message
naming the conflicting path.

---

## Area 4 — the verifier never looked at `Watch/`

**Classification: confirmed gap.** Priority signing correctness (P0).

### Root cause

The signed tree is described in three places, and they disagreed:

* **The engine** (`Vendor/Zsign/src/bundle.cpp:81-124`) signs by *path suffix*, not folder name:
  `GetObjectsToSign` recurses the whole tree collecting `.app`, `.appex`, `.framework` and
  `.xctest` as bundles (deepest first), then separately collects every `.dylib` file to sign in
  place. So a retained `Watch/*.app` is signed exactly like a PlugIn.
* **The pre-sign audit** (`NestedBundleAudit.bundles(in:)`) scans `PlugIns`, `Extensions` and
  `Watch`, and its own comment states that "Watch apps are not app extensions, so they remain in
  the target and must still be covered".
* **The post-sign verifier** scanned `["Frameworks", "PlugIns", "Extensions"]` — no `Watch`.

`SigningHandler._removeWatchIfNeeded` only deletes watch apps **without** an Info.plist, so a
retained watch companion is normal. The consequence: with the preflight override ("Sign Anyway") in
play, an uncovered or unsigned watch companion produced a clean verification report and then failed
on the device with nothing in the log to explain it. The audit had been checking that bundle all
along; the verifier that runs *after* the sign could not see it.

Call order was verified as correct, since it is what makes the audit's comparison valid:
`_modifyPluginIdentifiers` (line 119) runs before `_removeUnsupportedNestedBundlesIfNeeded` (148)
and `_auditNestedBundles` (192), so coverage is judged on post-rename identifiers as
`rewrittenIdentifier`'s documentation requires.

### Fix

`SignatureVerifier.nestedBundleFolders` is now `["Frameworks", "PlugIns", "Extensions", "Watch"]`,
with a comment recording the engine evidence. The existing severities apply unchanged: an unsigned
nested bundle is a `.warning`, an identifier the embedded profile does not cover is a `.failure`.

No gate or test pinned the old list, and the only `Watch/` fixtures in the suite belong to
`NestedBundleAuditTests.swift`, so nothing else moved.

### Tests

Two tests in `VexSignTests/SignatureVerifierTests.swift`:

* `testRetainedWatchCompanionIsNotInvisibleToVerification` — a watch app the exact-App-ID profile
  does not cover yields both `.nestedIdentifierUncovered` (failure) and `.unsignedNestedBundle`
  (warning, subject `ExampleWatch.app`), and `requireAcceptable()` throws. The fixture names carry
  no spaces on purpose: `URL.appendingPathComponent` percent-encoding of a space would make the
  directory name on disk and the `lastPathComponent` the verifier reports disagree, and a test that
  passes because two strings both contain `%20` is not testing anything.
* `testCoveredAndSignedWatchCompanionIsNotReported` — the positive control, so scanning `Watch`
  surfaces problems instead of inventing them. It uses a team-wildcard profile, because
  `coverage(of:includes:)` matches an exact App ID against one identifier only, and writes a real
  `LC_CODE_SIGNATURE` into the watch executable, because the fixture helper emits an *unsigned*
  binary when entitlements are `nil`.

Both details were checked against the helpers before being relied on; either one assumed wrongly
would have produced a test that passes for the wrong reason.

### Recorded as a limitation, not fixed

A loose `.dylib` is signed by the engine but is not reported by the verifier, and `.xctest` is
signed but does not ship. Neither was added to `nestedBundleExtensions`: that list is consumed by a
check that resolves `Bundle(url:).executableURL`, which a loose dylib does not have, so listing
`.dylib` would report **every** dylib as unsigned whether or not it is. Inspecting dylibs needs a
Mach-O read of its own. Treating `.xctest` as uncovered would start blocking IPAs that sign fine
today, with no evidence any user ships a test bundle. Both exceptions are asserted explicitly in
the new gate so the list cannot grow silently in either direction.

---

## Area 3 — an identity without a private key was accepted

**Classification: latent hazard, fail-open. Fixed fail-closed.**

### Root cause

`SideSign/Sources/Certificates/PKCS12Parser.swift:19` returned
`(certDER, parser.privateKeyDER ?? Data())`. A PKCS#12 carrying a certificate but no usable private
key therefore produced an identity with an **empty** key, which `KeyStore.init(p12Data:)` stored
without any non-empty or certificate↔key match check. The same `catch` also re-wrapped a
`CertificateError` in another `CertificateError`, producing
"PKCS#12 import failed: PKCS#12 import failed: …" and burying the reason.

Reachability was traced rather than assumed: `PKCS12Parser.extract` has exactly one caller
(`KeyStore.swift:52`), and `KeyStore(p12Data:)` has **no** callers in the repository — the only
`KeyStore` construction is `DeveloperPortal/Certificates.swift:113`, from a freshly generated CSR,
which matches by construction. So this is not a live bug today; it is a public API of a package the
app ships, waiting for its first caller.

For contrast, the native path is strict and was left alone:
`NativeSigningIdentityCrypto.matchesPublicKey` / `validateCertificate` require
`subjectPublicKeyInfoDER == record.publicKeyDER`, `organizationalUnit == record.teamIdentifier`, a
finite `notBefore < notAfter`, an optional now-window, and cap input at 64 KiB. VexSign's own
pre-flight (`ZsignEngine.identityProblem`) fails closed on a missing profile, an unreadable
certificate or a certificate absent from the profile, and deliberately **passes** when the profile
names no certificates — documented as "unknown, never mismatch".

### Fix

`extract` now throws `CertificateError.pkcs12ImportFailed(cause: "PKCS#12 archive contains a
certificate but no private key")` when the key is absent or empty, returns the real key bytes, and
rethrows a `CertificateError` unchanged instead of double-wrapping it. The guard sits at the seam
that read the archive, which is the only place the reason is still known.

### Test coverage — and why it is a gate rather than a Swift test

`tools/test_signing_identity_policy.py` pins that `extract` contains no `?? Data()`, does contain
the non-empty key guard and its message, returns `keyDER`, rethrows `CertificateError` unchanged,
and that `KeyStore`'s only p12 path goes through `extract`.

No Swift test was added, deliberately. `SideSign` has no test target, there is no
certificate-only PKCS#12 fixture in the repository, and the only way to reach the guard from a test
would be to feed malformed bytes to a third-party ASN.1 parser. That parser is never exercised with
untrusted input in production today (its one entry point has no callers), so a crash-on-garbage
behaviour would be undiscovered — and a test that crashes the native CI job instead of failing it
is worse than no test. The gate runs in `make verify`, is deterministic, and cannot crash.

---

## Area 1 — native Apple signing and production CMS verification

**Classification: architectural risk — deliberately incomplete and fail-closed. No fix.**

The production CMS verifier is real and strict. `NativeAppleProfileCMSVerifier.verifyAppleProvisioningCMS`
requires a finite timestamp, exactly one matching signer certificate, a pinned leaf common name, a
basic-X509 trust built from the presented chain, a trust result of `.unspecified` (so an explicit
user trust override is **not** accepted as a production Apple anchor), a pinned issuer common name,
and no network access, custom anchors or trust bypass. `verifySignature` re-checks the key
attributes before verifying. `NativeProvisioningProfileValidator.validate` bounds the CMS to 1 MiB
and rejects a non-finite clock.

The finding is that **none of it is reachable from the shipping app**:

* `NativeProvisioningProfileValidator.appleCMS()` — the only factory that installs a verifier — has
  no production caller.
* `SideSignAccountBridge.init` therefore defaults to `.init()`, whose `verifier` is `nil`, so
  `isConfigured` is `false` and `requireCMSVerification()` throws
  `.cmsVerificationUnavailable` before any store, context or crypto I/O (lines 825 and 912).
* `SigningMethodCapabilities.report` declares `nativeAppleAccountSigning: .notIntegrated`, with the
  comment "Replace only when a concrete native account adapter is wired into provisioning/signing.
  Never enable from preferences or `canOpenURL`."

That combination is the correct fail-closed posture: the capability is not claimed, the UI is not
offered the flow, and even a caller that reached the validator directly would be refused rather
than handed an unverified profile. Wiring it up would require real Apple account credentials and
on-device verification, so doing so here would be exactly the speculative change the assignment
forbids. `tools/check-native-handoff.py` already gates the capability claim against
`NativeSigningManager.swift`, `ProvisioningFlowView.swift`, `NativeAccountBackend.swift` and
`docs/NATIVE_SIGNING_HANDOFF.md`.

Also verified while in this area, because it is load-bearing and counter-intuitive: the provisioning
polarity is translated exactly once (`Request.engineEmbedProvision == !removeProvisioning`), the pin
*writes* `embedded.mobileprovision` when its flag is `true`, and
`SigningHandler.swift:245` derives `requiresEmbeddedProfile` from the same option.
`ZsignEngineTests.swift:84` already asserts the two stay equal, so no new pin was added.

---

## Area 5 — concurrent signing, downloads and installation

**Classification: sound. No fix.**

* `AppOperationRegistry` gives exclusive ownership per stored copy
  (`"signed:<uuid>"` / `"imported:<uuid>"`) under an `NSLock`, and a `Lease` releases in `deinit`,
  so ownership survives cancellation until the worker actually exits. `release` compares the owner
  `UUID`, so a late release cannot free someone else's lease. An app with no `uuid` gets a unique
  anonymous key, which is correct: there is no stored copy to protect.
* `Storage+Shared`'s bulk delete acquires one lease per key into a local array; if any acquisition
  throws, the array goes out of scope and every lease already taken is released by `deinit`. No
  partial-lock leak.
* `InstallQueue._prepareNext` is a lookahead that may find the next app busy. Its swallowed `Busy`
  is harmless by construction: `AppInstaller` line 236 falls back to `_createPackage()` when
  `_preparedPackage` is `nil`, and the lease that matters is acquired in `start`, which **does**
  report `Busy` through `_finish(.failure(error))`.
* `SigningExecutionGate` serializes the native critical section without blocking the main thread.
  Cancellation is handled on both sides of the handoff: `acquire` refuses an already-cancelled task,
  `cancelWaiter` removes a waiter by id, and `release` transfers ownership directly to the next
  waiter so new arrivals cannot jump the queue. `withPermit` calls `acquire()` **outside** its
  `do`/`catch`, so a failed acquisition cannot trigger a spurious `release()` — and re-checks
  `Task.checkCancellation()` inside, because cancellation can race the handoff from the previous
  owner. The operation runs on the caller's executor (`nonisolated`), keeping the actor responsive
  while a synchronous native operation is busy. `SigningExecutionGateTests.swift` already covers
  the queueing.

**Later finding — the classification above was too narrow.** The leases protect each *stored copy*.
Nothing protected the *temporary directory* every sign works in and every install packages its
archive in: with Auto Cleanup's "Clear Temporary Files" on, one operation finishing cleared that
directory under any other operation still running. Automatic cleanup now asks
`AppOperationRegistry.hasActiveOperations` first and leaves the directory alone while any lease is
held. See Issue 4 in the
[follow-up](signing-and-installation-lifecycle.md#follow-up--re-signing-with-saved-settings-the-record-of-a-signed-copy-and-install-verification);
`CleanupOperationGuardTests` covers the rule.

A second gap of the same kind was found later: nothing protected a copy between the moment its
bundle is moved into the library and the moment its row is committed, so a leftovers pass in that
window could delete it. Signing and importing now announce the copy they are producing to the same
registry, leftovers wait like the temporary directory while any lease is held, and Clean Now
follows both rules. See Issue 8 in
[Follow-up 2](signing-and-installation-lifecycle.md#follow-up-2--what-a-successful-sign-leaves-in-the-library).

---

## Area 6 — cancellation, stale callbacks and background recovery

**Classification: sound. No fix.**

* `UnifiedTaskCenter`'s history recovery reads snapshots from disk and then filters out any id
  already live — "Live work may have started while disk IO was running" — before marking the rest
  `.interrupted` with `confirmationReason = "interrupted-process-exit"`. A restarted app therefore
  cannot resurrect or overwrite in-flight work.
* `cancelDownload` removes the import observer and any pending integrity decision before cancelling
  the URL session task, so a completion for a cancelled download has nothing left to write to.
* The install-side stale-callback race was the subject of the first report: `InstallQueue` now
  carries a `runGeneration`, `mayEndAttempt(registered:reportedByCompletion:)` and
  `mayDismissFinishedRun` decide whether a completion still belongs to the current run, and
  `LibraryStatusStore.applyingActiveInstallation(to:request:now:)` is applied last at all three
  publication sites so a late installer cannot overwrite a live attempt.
* `SigningHandler` checks `Task.checkCancellation()` after verification and before `move()`, so a
  cancelled run does not register an artifact.

**Later findings — two gaps this review did not reach.** Both are install-side, and both are
recorded under Issue 6 in the
[follow-up](signing-and-installation-lifecycle.md#follow-up--re-signing-with-saved-settings-the-record-of-a-signed-copy-and-install-verification):

* An install treated as declined (`.success(.cancelled)`) left its task record open. The last app
  in a queue was then recorded as Completed; otherwise the next app ran on the declined app's
  record. `InstallQueue` now closes that record as Cancelled before moving on.
* The deadlines `AppInstaller` keeps beside its watcher were single sleeps, so they also ran out
  while iOS had the app suspended and then acted ahead of the watcher's next device check. They now
  count running time (`InstallDeadlineBudget`). This one is reasoned from the code; it has not been
  observed on a device.

---

## Area 8 — cloud signing authentication, authorization and job isolation

**Classification: no bug found. No fix.** Read end to end: `app.ts`, `security.ts`, `jobs.ts`,
`worker.ts`, `signer.ts`, `contracts.ts`, `migrate.ts`. The specific question asked — can one user
reach another user's cloud job or artifact — is answered no, at four independent layers:

1. **Authentication.** JWT verified RS256-only against pinned `allowedIss`/`allowedAud`, requiring
   `sub`/`exp`/`iat`, `maxAge` 3600 s. Claims are then re-parsed with Zod (`sub` 1–200 chars), and
   a token is rejected if `iat` is more than 30 s in the future or its lifetime exceeds an hour.
   Scope `signing:write` is required.
2. **Authorization on every read.** `/api/jobs/:id` and `/api/queue` filter `WHERE owner = $n`.
   Assets are validated `WHERE owner = $1 AND id = ANY(...)` per kind, returning 404 rather than 403
   so existence is not disclosed. `submitJobs` takes `pg_advisory_xact_lock(hashtextextended(owner,
   0))`, enforces a per-owner quota of 100, and scopes idempotency to `owner + key` **and** an HMAC
   `request_hash` over `[kind, ipaId, p12Id, provisionId, password, webhook]` — reusing a key with a
   different request is a 409, not a replay of someone else's job.
3. **The worker never trusts client input for ownership.** `processJob` reads
   `SELECT * FROM jobs WHERE id = $1` and takes the owner **from the database row**; `fetchAsset`
   then scopes `WHERE id = $1 AND owner = $2 AND kind = $3`. There is no path by which a request
   body can name another tenant's asset.
4. **Isolation on disk and in process.** Assets stream into `mkdtemp` + `chmod 0o700` via
   `createWriteStream(..., { flags: 'wx', mode: 0o600 })` with byte-count and SHA-256 enforcement;
   the output must be a regular, non-symlink, single-link file between 4 bytes and 2 GiB with ZIP
   magic. The signer is spawned with `shell: false`, `detached: true`, an environment reduced to
   `PATH`/`LANG`/`HOME`/`TMPDIR` (both pointed at the job directory), secrets over **stdin only**,
   a 10-minute timer, a 1 MiB stdout cap, and `process.kill(-pid, 'SIGKILL')` against the whole
   process group. `finally` removes the directory; `finish()` clears `sealed_password`.

Rate limiting is per tenant, not per IP — `vexsign:tenant:<sha256(sub)>:<minute>` capped at 60/min
on top of `@fastify/rate-limit` at 120/min — so it cannot be circumvented by cycling addresses.
Passwords are sealed with AES-256-GCM using a 12-byte nonce and **the job id as AAD**, so a sealed
password cannot be replayed across jobs. Uploads are size-guarded during the stream (10 MiB for
`p12`/`provision`), require ZIP magic for `ipa`, and on any error call `upload.abort()` plus an S3
`DeleteObject`. Webhooks must be `https:`, carry no userinfo or hash, match an allowlist entry by
exact `url.href`, are leased with `FOR UPDATE SKIP LOCKED`, retried at most 8 times with 5-minute
backoff, signed with a per-URL HKDF HMAC-SHA256, and fetched with `redirect: 'error'` and a 10 s
timeout. Errors map Zod failures to 400 and never leak payloads, signer output or SQL; the logger
redacts `authorization`, `cookie`, `req.body`, `req.query` and `res.headers.location`, and
serializes `req.url` path-only. Helmet sets CSP `default-src 'none'`, `frame-ancestors 'none'`,
`no-referrer`.

Three things that look like findings and are not, recorded so they are not re-raised:
`verifyCapability`'s length check before `timingSafeEqual` is required by that API and cannot leak,
because a base64url SHA-256 capability is always 43 characters; install, manifest and download
capability links are intentionally **not** owner-scoped — they are shareable OTA links — but are
HMAC-bound to `id:expires` and capped at 24 h; and `input.password = ''` runs only on the success
path, because JavaScript cannot guarantee zeroization, which the code already documents.

---

## Area 9 — guest-host packaging and runtime reliability

**Classification: no bug found. No fix.**

The candidate was `EmbeddedContainerRuntime.stageIPA`, which copies the IPA into guest-owned
`Caches/VexSignEmbeddedImports/<uuid>/Import.ipa`, validates it, hands the path to the host, and
then deletes the whole staging directory in a `defer`. If the host retained only the path, that
would be a use-after-delete. It does not: `VEXEmbeddedRuntimeStageIPA` is a synchronous
`objc_msgSend` into `LCSharedUtils.vexSignStageIPA:` (`EmbeddedContainer/patches/combined-host.patch:58`),
which — inside `@synchronized(self)` — canonicalizes and resolves symlinks, requires the path to be
a regular `.ipa` **inside** the resolved home directory, refuses if an import is already pending,
copies the file into `Documents/Inbox/VexSign-<uuid>.ipa`, persists that path in
`VexSignPendingImport` and calls `synchronize`, and rolls back both the file and the preference if
either step fails. The copy is complete before the guest's `defer` runs.

The staging copy also passes through `ArchiveSafetyValidator.validate`, so it now benefits from the
area-7 duplicate-entry fix.

`VEXHostRuntime` refuses unless the build declares itself a guest or primary host, `LCSharedUtils`
is loaded in-process, and it answers `vexSignCombinedHostAvailable`. There is no
`UIApplication.openURL`/`canOpenURL` external-app fallback, and the comment says so.
`VEXEmbeddedRuntimeOpen` requires the main thread. `VEXEmbeddedRuntimeGuestInfo` passes through only
two typed string fields and returns `nil` for anything else, and `ContainerGuestState.derive` maps
an unusable answer to `.unknown` — never to `.notImported` — with `.unavailable` when the runtime is
not loaded. `supportsScheduledGuestTasks` is `false` for guest builds because a BGTask launch would
restart the host UI without the guest's task handlers.

---

## Files changed in this phase

Production (9 files, +186/−13):

| File | Change |
|------|--------|
| `.github/workflows/embedded-container.yml` | +2 path filters (`push` and `pull_request`) for the app files the smoke package compiles |
| `NimbleKit/.../UIApplication+open_private.swift` | `openApp` guards both selectors, dispatches through `@convention(c)`, returns `Bool`, `@discardableResult` |
| `VexSign/Utilities/AppLauncher.swift` | **New** adapter; reports launch failure to the user |
| `VexSign/Views/Library/Install/InstallCardView.swift` | Launch through `AppLauncher` |
| `VexSign/Views/Library/Install/InstallQueueWindow.swift` | Launch through `AppLauncher` (2 sites) |
| `VexSign/Views/Library/LibraryCellView.swift` | Launch through `AppLauncher` |
| `VexSign/Utilities/ArchiveSafetyValidator.swift` | Duplicate-destination detection + `.duplicateEntry(String)` |
| `VexSign/Utilities/Signing/SignatureVerifier.swift` | `nestedBundleFolders` gains `Watch` |
| `SideSign/Sources/Certificates/PKCS12Parser.swift` | Reject an absent/empty private key; stop double-wrapping `CertificateError` |

Plus `VexSign/Resources/Localizable.xcstrings` (3 keys added by `tools/sync-strings.py --write`)
and `Makefile` (2 new gates wired into `verify`).

Tests and gates (5 files, +263):

| File | Change |
|------|--------|
| `tools/test_workflow_policy.py` | +2 tests: derived trigger coverage for every compiled app source; test manifest ↔ disk equality |
| `tools/test_private_launch_policy.py` | **New**, 6 tests |
| `tools/test_signing_identity_policy.py` | **New**, 6 tests |
| `VexSignTests/ImportAndInstallationTests.swift` | +6 duplicate-entry tests |
| `VexSignTests/SignatureVerifierTests.swift` | +2 watch-companion tests |
| `VexSignTests/PrivateLaunchSurfaceTests.swift` | **New**, 2 tests |

No existing test was disabled, skipped or weakened. No security protection was relaxed: every change
either adds a rejection, adds a guard, or widens what is reported.

## Validation actually performed

| Check | Result |
|-------|--------|
| `make verify` | **EXIT 0** |
| `make docs-check` | **EXIT 0** |
| Gate self-tests | **264 Python tests OK** (250 before this phase) |
| `quick_check.py --no-swiftc` | ✅ no build-breaking problems (9 checks) |
| Dependency pins | ✅ 42 pins agree |
| `sync-strings.py --check` | ✅ 3275 literals / 3555 keys |
| `error-discipline.py` | ✅ 239 `try?` across 95 files — none above baseline |
| `singleton-freeze.py` | ✅ 62 singletons across 61 files — none above baseline |
| `concurrency-discipline.py` | ✅ 6 escapes across 5 files — none above baseline |
| Bracket balance on all changed Swift | ✅ 0 problems in 29 files |
| Each new gate proven to fail when its fix is reverted | ✅ 3 of 3 (workflow filter, launch guard, `Watch` folder) |

**Not performed, and not claimed:** there is no Swift toolchain in this environment — no `swift`,
`swiftc`, `xcodebuild` or `docker`. `make test`, `make lint`, `make strict-concurrency`, the IPA
build and every physical-device check were **not run**. The Swift changes were hand-verified against
the declarations they call (fixture helpers, `coverage(of:includes:)`, `_machO(entitlements:)`,
`ValidationError`, `CertificateError`) and bracket-checked, which is not compilation.

### Since then: verified on CI, on real macOS runners

Everything the paragraph above could not run has now run, on GitHub Actions macOS arm64 runners
against this branch. Two things came out of it that are worth recording separately from the
ten areas, because both were discovered only by compiling.

**`main` did not build.** At the branch point `0074f86` the iOS target did not compile, so the
`tests` job reported `totalTestCount=0` — the XCTest suite had never executed against this source.
Four pre-existing defects blocked it, and Swift reports them in batches, so each fix unmasked the
next: `PackageDownloadURLPolicy` did not conform to `URLSessionDownloadDelegate` (`b01311e`);
`FR.swift` captured a non-escaping completion in an escaping closure and `LibraryCellView`'s
`_buttonActions` returned a bare `if`/`else` from a non-builder context (`5bff2b3`); and four
first-party warnings failed the Build check, which treats warnings as errors — three dead `?? ""`
on a `LocalizedError`'s non-optional `localizedDescription`, and a captured `var self` read from an
inner concurrent closure (`87c86b0`). None of these came from this branch's changes; all four files
are byte-identical to base at the affected lines. No warning was baselined and none was suppressed.

**The first real test run found seven failures.** 1013 tests ran, 1004 passed. Root causes, in the
order they were fixed:

| Commit | Failures | Cause |
| --- | --- | --- |
| `c25790f` | 3 in `InstallConfirmationTests` | Measured the 120 s verification window from the wrong origin: `Limits.verify` runs "after progress ends", and the helper puts that at epoch+10, so the window closes at epoch+130 — the assertions used `at(121)` |
| `c25790f` | 1 in `InstallConfirmationTests` | An unstructured `Task` inherited the test's actor, which the next line then blocked on a semaphore, so the probe could never be entered and the synchronisation guard timed out. Now `Task.detached` |
| `78d7ca1` | 1 in `SigningWorkflowTraceTests` | **Production.** `SigningWorkspaceStep.status` returned `.active` for Verify whenever the run was still live, withholding verification evidence the engine had already recorded. "Still running" is not a terminal outcome and no longer outranks it; `.failed`/`.cancelled` still do |
| `78d7ca1` | 1 in `SigningWorkflowTraceTests` | The test asserted Customize completed, but its own fixture never reports `.modifying`, the only stage that reaches it. Now asserts `.pending`, which pins the evidence-only contract more strictly than the original |
| `1d6b12f` | 1 in `GitHubReleaseSourceTests` | The cached-payload assertion searched the raw bytes for `github.com/example/reader`, but `JSONSerialization` escapes forward slashes by default, so the bytes read `github.com\/example\/reader`. Now decodes the payload and checks four specific values |

One further failure, `testPauseAllIncludesQueuedTransfersAndResumePreservesTaskOwnership`, appeared
in a single run and not in the runs either side of it. The only file that changed between those two
runs was `InstallConfirmationTests.swift`; `DownloadManager.swift`,
`DownloadManager+Delegates.swift` and the test itself are byte-identical. Same code, different
outcome — intermittent, and not introduced here. It has passed since.

**Final state, `1d6b12f`: every check on PR #152 passes** — `build · VexSign Debug (unsigned)`,
the embedded-container/native `build` (which compiles the `PKCS12Parser` change and runs the 34
native test files), `tests · VexSignTests (simulator)`, tvOS, visionOS, watchOS, `quick`, `checks`
and `links`. `link-smoke` skips by design, since this branch changes no dispatch-only path. The
suite is 1013 tests with 2 skipped and no failures; a passing tests job publishes no count summary,
so the exact pass figure for that run is not in the annotations — the totals above come from the
last failing run, which differed by the single test `1d6b12f` fixed.

Still not performed, and still not claimed: `make lint`, `make strict-concurrency`, the signed IPA
build and every physical-device check. Those need a Mac with a device attached.

To run them on a Mac:

```bash
make verify
make test
SIM_ID="$(python3 .github/scripts/select_simulator.py --print-id)"
xcodebuild test -workspace VexSign.xcworkspace -scheme VexSignTests -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_ID" -derivedDataPath "$TMPDIR/TestDerivedData" \
  -only-testing:VexSignTests/SignatureVerifierTests \
  -only-testing:VexSignTests/ImportAndInstallationTests \
  -only-testing:VexSignTests/PrivateLaunchSurfaceTests \
  -parallel-testing-enabled YES -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  COMPILER_INDEX_STORE_ENABLE=NO ONLY_ACTIVE_ARCH=YES
```

The native-suite changes (area 10) are validated by the workflow itself:

```bash
python3 NativeSigning/prepare_smoke.py && swift test --package-path .build/native-signing-smoke
```

## Remaining limitations

1. **Nothing in this phase was compiled or run as Swift.** The four Swift production changes and ten
   Swift tests need `make test` on a Mac before they can be called verified.
2. **Area 1 is still not integrated.** `nativeAppleAccountSigning` remains `.notIntegrated` and
   `appleCMS()` still has no production caller. This is deliberate and fail-closed, but it means
   native Apple-account signing is not a usable path in the shipping app.
3. **Loose `.dylib` and `.xctest` are signed but not reported** by the verifier, for the reasons in
   area 4. Both are pinned as explicit exceptions so they cannot change silently.
4. **Validate-then-extract is not atomic** on the `Zip`-based paths. Exploiting the window needs a
   concurrent writer inside the app's own sandbox.
5. **`openApp` returning `true` means dispatched, not launched.** iOS confirms nothing, so the Open
   button can still report success for an app that does not come to the foreground.
6. **Area 3's guard has no Swift test**, for the reasons given. It is pinned by a source gate.
7. **No area-8 change was made**, so the cloud service's isolation guarantees are as-found, not
   as-improved. They were read, not load-tested; a tenant-isolation penetration test against a
   running deployment is still worth doing and cannot be done from this repository.

## Physical-device checks for these ten areas

These extend the 20 acceptance steps in the first report. None of them has been performed.

1. **Area 2 — Open button.** Sign and install any app. Press **Open** in the library cell, in the
   install card after success, and in the completion sheet (both the single-app button and the
   multi-app menu). The app must come to the foreground and **VexSign must not crash**. Then repeat
   with an app whose install state is unknown (fresh library row, no probe result yet): the Open
   button is shown there on purpose, and it is the path that used to be silently dead.
2. **Area 2 — degraded build.** If a future iOS build filters `LSApplicationWorkspace`, pressing
   Open must show "This iOS version does not let VexSign open apps. Open it from the Home Screen."
   and must not crash. This cannot be forced on a current device; it is the behaviour to confirm if
   it ever appears.
3. **Area 4 — watch companion.** Sign an IPA that contains `Watch/<App>.app` with an Info.plist and
   a profile that does not cover its identifier. Preflight must refuse it. Press **Sign Anyway**,
   and the verification report must now name the watch app as uncovered instead of passing clean.
   Repeat with a team-wildcard profile: it must sign and verify clean.
4. **Area 7 — conflicting archive.** Unzip a tweak/IPA whose archive contains the same path twice
   (for example `Payload/App.app/Info.plist` and `Payload//App.app/Info.plist`). It must be rejected
   with "The archive contains conflicting entries for the same path: …" rather than extracting with
   the last entry winning.
5. **Area 7 — ordinary archives.** Import a normal IPA and a normal tweak. Both must extract
   unchanged, including one with explicit `Payload/` directory entries.
6. **Area 9 — guest staging.** In a combined LiveContainer host build, stage an IPA into the guest
   container. It must land in `Documents/Inbox/VexSign-<uuid>.ipa`, survive the guest's staging
   cleanup, and import on the next host launch. Staging a second IPA before the first is consumed
   must be refused, not queued silently.
7. **Area 10 — CI.** From a branch, change only
   `VexSign/Backend/Services/AppleAccountSessionCoordinator.swift` and open a pull request.
   `embedded-container.yml` must now appear in the check list and run
   `swift test --package-path .build/native-signing-smoke`. Before this fix it did not.
