# Native account signing: storage, session codec and link-smoke foundation

This is an **isolated dependency/link experiment**, not an enabled Apple-account
login implementation. The normal VexSign target/package graph and imported-
certificate workflow do not depend on this generated package. No Apple login,
certificate creation/revocation, provisioning, signing execution or account data
is used by preparation/building the smoke library.

## Pinned graph

`inputs.lock.json` pins SideSign's Odysseus source revision, all eight selected
source-package revisions, original manifest SHA-256 values and the required
Anisette Unicorn binary URL/checksum. It includes SwiftASN1 and the existing
VexSign Zsign/OpenSSL pins, not just SideSign's direct branch dependencies.

Preparation checks the existing app's Zsign gitlink and OpenSSL resolved revision.
If those change, update/review the smoke lock rather than accidentally testing a
different signing stack. Every cloned repository is checked out at its locked
commit; original manifests are hash checked before rewriting. The generated
source dependencies are local paths, never floating branch resolution. Unexpected
source requirements, alternate manifests, submodules or binary inputs fail closed.
The Odysseus application's unrelated submodules are not initialized; only its
regular `SideSign` subtree is copied.

### Packaging overlays, explicitly scoped to this smoke graph

CodeSignKit and GSACryptoKit each declare an unused **test-only** `OpenSSL` binary
target, whereas Zsign uses the existing app's actual OpenSSL package. The smoke
manifests for these two packages retain their library products, Sources and
Crypto/CryptoExtras/SwiftASN1 dependencies but omit CLI/tests and their duplicate
OpenSSL targets. Crypto library source code and licenses are unchanged by these packaging overlays.
A separate, explicit logging-source privacy overlay now applies to SideSign and
AnisetteKit (see below). This is not a claim that upstream's test suites or every
crypto combination pass.

All manifest originals and overlay hashes are recorded in the generated directory.
Anisette's required Unicorn binary target is retained with its upstream checksum;
SwiftPM must verify the actual download. OpenSSL is the pinned repository's local
XCFramework. Source pins/checksums are integrity controls, not a completed security
or licensing audit of all native code and binary provenance.

## Prepare / compile (macOS, Xcode 26.2+)

```sh
python3 NativeSigning/prepare_smoke.py
cd .build/native-signing-smoke
xcodebuild -scheme NativeSigningLinkSmoke -destination 'generic/platform=iOS' \
  -sdk iphoneos -derivedDataPath ../native-signing-device -configuration Release \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

Preparation deliberately requires a **new** work directory. It never deletes or
reuses an existing one; choose `--work` explicitly for another attempt and retain
failed graphs/logs for diagnosis. Dependencies/build outputs live under ignored
`.build/`, not Git. The dynamic smoke library exports references to both
`DeveloperPortal.shared` and `Zsign.sign`, forcing actual link work rather than
only testing `import` syntax. No entry point is executed by this build.

Or manually dispatch **Native account signing · link smoke**. It is read-only,
opt-in, uploads only logs/provenance, and does not publish binaries. An optional
arm64 Simulator build checks another ABI slice; it does not execute tests.

**Not run here:** this Linux workspace has no Swift/Xcode and cannot download
GitHub release-asset binaries. Native compile/link, binary slices and real device
behavior are unverified. The application must not advertise native account signing
until a concrete adapter is integrated and verified.

## Device-only account session store

`VexSign/Security/AppleAccountCredentialStore.swift` implements the Security adapter:

- Dedicated `com.vexsign.apple-account.sessions.v1` service and opaque UUID records.
- `WhenUnlockedThisDeviceOnly`, non-synchronizing, no explicit shared access group.
- Add-only session records: duplicates fail without overwriting the accepted data.
- Exact-record, idempotent deletion; errors propagate rather than claiming removal.
- Noninteractive reads; only item-not-found returns nil. Locked, unauthorized and
  corrupt replies remain errors, not silent sign-out.
- Bounded opaque session bytes; no Apple-password field, preferences, file export,
  logging or remote transport. The future adapter must encode only SDK session
  material and validate its version/format on decode. This byte store cannot
  determine whether a caller deliberately passes the wrong kind of bytes.
- Compatibility guard rejects the experimental guest-host build. That is not a
  security boundary against malicious native code in the same privileged process.
- Stateless system client is Sendable; injectable test clients need no unchecked
  concurrency annotations. Security calls are synchronous: the coordinator should
  use a worker/serialized executor, not block credential UI with storage work.

`AppleAccountSessionCoordinator` now exclusively owns durable persistence and
transient state on one worker actor. Stale/duplicate callbacks are rejected before
storage; commit and metadata acceptance have no intervening actor suspension.
Team hints persist before publishing team/context changes. Sign-out invalidates
state before journaled cleanup; failures block fresh login until explicit retry.

`AppleAccountSessionRepository` and `AppleAccountResumeJournalStore` now provide
a shared durable ownership/resume implementation (see below). The coordinator
now owns its persistence value directly; the SDK adapter is still absent. Do not put journal/index state in
preferences, and do not treat restored references as authenticated accounts.
Local sign-out never revokes a portal certificate.

Deterministic XCTest coverage uses a local recording client (no real credentials).
Real device Keychain accessibility, locking, reinstall/restore behavior and signed
host entitlements still need native integration tests. Swift Data copies are not
promised to be zeroized, nor is flash deletion promised to physically erase bytes.

## Next integration gate

1. Compile/link the selected graph and resolve any API/ABI/native artifact issues.
2. Promote/validate the isolated backend assembly with real primary-app
   Keychain stores and the configured concrete anisette provider. The bridge now wires
   login/revalidation/2FA to the actual shared durable coordinator source, but the
   ordinary app target does not yet link or instantiate that backend.
3. Connect actual SideSign authentication/2FA/team enumeration with explicit
   anisette consent, cancellation and Keychain rollback. No dummy login screen.
4. Add provisioning/signing/install/refresh through the existing task pipeline.
5. Port primary-host runtime lifecycle into VexSign separately; do not ship the
   guest-host prototype as that architecture.

Preserve SideSign/SDK licenses and aggregate AGPL/GPL source obligations when
integrating/distributing code. Local dependency preparation retains upstream
license files; the smoke workflow does not publish compiled artifacts.

### Whole-app dependency reconciliation remains separate

The normal application currently pins swift-crypto **3.15.1** and swift-asn1
**1.5.1**. This isolated SDK graph requires **4.3.1** and **1.6.0** respectively.
Even a passing isolated link build would not prove the complete app can resolve
or compile with those versions. Review all consuming package constraints and API
compatibility before changing the application graph; the existing pins are
unchanged.

### Coordinator coverage

`AppleAccountSessionCoordinatorTests` adds eight XCTest cases for stale/duplicate
callbacks, sign-out versus late success, failed-deletion retry/login blocking,
insert failure, invalid metadata, task cancellation/late registration, team-context
invalidation and stale failure during 2FA. They are written but have not run in
Xcode. Test storage uses `OSAllocatedUnfairLock`, not real Keychain items.

A cancelled SDK task can still finish; operation/context checks remain mandatory.
Cancellation does not undo portal changes. There are no suspension points during
local insert/accept or invalidate/delete, and the durable journal now tracks interrupted inserts and deletion intent.
A failed initial intent write still cannot promise durable sign-out.
Do not enable account UI, restoration, provisioning or background refresh on this
foundation before the SDK adapter and durable repository integration are verified.

## Versioned SDK session codec (isolated; not app-integrated)

`Codec/SideSignSessionCodec.swift` targets the pinned SideSign API. The preparation
step rejects an SDK revision change without an explicit codec review. The generated
library builds the codec and exports function references; preparation records
SHA-256 hashes for first-party codec, smoke, package and test inputs as provenance.

- Schema 1 allowlists account identifier/Apple ID, DSID, auth token, Xcode version,
  optional creation date and a required effective expiration date. These are
  **secret plaintext bytes intended only for device-only Keychain storage**.
- It does not serialize the SDK `AuthSession` wholesale. Account display names,
  anisette snapshots/one-time-password headers and machine passwords are omitted.
  A non-nil SDK `machinePassword` is rejected, not silently dropped; supporting it
  requires a separate semantic/security review. This does not assert that field
  is the user's Apple password.
- Unknown expiry is rejected. When both explicit expiry and creation + TTL are
  available, the earlier deadline wins. Invalid dates/TTL, expired records,
  blank/control-character fields and oversized records fail explicitly.
- Schema/SDK mismatches, malformed/missing fields and unexpected JSON fields fail
  closed, without propagating raw decoding errors or secret payload descriptions.
- `decodeForRevalidation` requires replacement anisette headers. Nonempty-field
  checks cannot prove their freshness/authenticity: the consented provider must
  supply fresh values. The decoded SDK session is only a candidate; server token
  revalidation and fresh team enumeration are mandatory before signed-in state.
  Expiry checks do not prove a token has not been revoked.

Eight synthetic-data XCTest cases are included in the generated
`NativeSigningCodecTests` target. They have **not run**; the existing manual link
workflow builds the library but does not execute these tests. Full SDK/native
compilation remains unverified. The normal app graph and unavailable-account UI
remain unchanged. The durable implementation below is now used by the worker coordinator;
SDK/UI integration and native validation are still pending.

## Durable session ownership and resume journal

`AppleAccountSessionPersistence` implements the journaled operations paired with
`AppleAccountResumeJournalStore`. The coordinator owns this value directly on its
worker actor. `AppleAccountSessionRepository` remains a standalone actor facade
for recovery clients/tests using the identical implementation. **Do not construct
both owners for one namespace.** SDK and authentication UI integration are absent.

The journal has a separate, fixed Keychain service/account and uses
`WhenUnlockedThisDeviceOnly`, synchronizable false, no explicit shared access group
and noninteractive reads. Updates atomically replace the journal row; only
item-not-found allows insertion. Other errors, duplicate insertion races,
malformed/unknown-schema/unknown-field records and inconsistent ownership fail
closed rather than becoming an empty account. Ownership is bounded to 16 UUIDs.
There is no journal deletion/purge API and no preferences/file fallback.

Commit ordering:

1. Persist a fresh UUID reservation before adding session bytes.
2. Add the insert-only session record.
3. Atomically replace the reservation with the selected reference. The team hint
   remains nil until explicit selection; saving a hint requires the same reference.

Recovery converts an interrupted reservation into pending deletion before touching
session bytes. Cleanup deletes exact owned UUIDs and persists each completion;
not-found deletion is idempotent. Sign-out persists deselection/deletion intent
before deleting bytes, so a failed delete is retryable after restart. A dangling
selected reference raises an error requiring explicit cleanup, not a silent new
login. A recovered candidate is only SDK-encoded bytes plus an optional team hint:
it must pass codec validation, fresh anisette and portal/team revalidation.

**Limits and integration requirements:**

- Exactly one repository instance must own this namespace in the primary app.
  Actor serialization is not cross-process/multi-instance locking or CAS. Do not
  let extensions/guests write the journal, or mix this with direct session writes.
- The persistence value deliberately does not implement the insert-only storage
  protocol: commit can throw *after persisting a reservation*. The coordinator now
  handles that error by invalidating the operation and requiring durable cleanup
  before retry. It no longer writes session bytes directly.
- If the initial sign-out-intent write itself fails, sign-out is not durable.
  The current instance blocks restoration/new commits until sign-out is retried;
  after process death the previous on-disk candidate may still exist. Surface the
  error, invalidate in-memory tasks/context, and retry after unlocking/fixing
  Keychain access. Do not claim credentials were removed when storage denied it.
- UUIDs are newly generated in a dedicated, exclusively owned namespace. This is
  not ownership attestation against malicious native code with host authority.
- SDK/network callbacks must carry operation UUIDs. Inside the worker actor,
  persistence and state mutation are synchronous, so no actor await separates
  commit from acceptance or durable team-hint persistence from context changes.
  No restoration may bypass server revalidation or automatically authorize a team.

Ten repository failure-injection XCTest cases recreate the repository over shared
recording storage to model interrupted writes and cleanup; six journal Security-
adapter tests cover policy, update/add/error behavior and invalid responses.
These **16 native tests are written, not run**. They do not prove real Keychain
atomicity/accessibility, OS termination behavior, entitlements or backup/reinstall
semantics. Native build/device validation remains deferred.

### Durable coordinator integration increment

The eight earlier coordinator XCTest cases now exercise the durable store path.
Six additional cases cover commit-before-metadata ordering, failed final commit
cleanup, team-hint persistence failure preserving phase/context, saved-account
replacement blocking, failed sign-out intent invalidating context and restart
recovery before a fresh login. All fourteen coordinator cases remain **unexecuted**.

`recoverCandidate()` on the coordinator is read-only with respect to transient
authentication state and is available only while signed out without pending
cleanup. `beginAuthentication()` reports `resumeRequired` if a candidate exists,
not an empty account. Resume acceptance is now wired through the isolated bridge
below, but is not linked into the ordinary application target.

## Real SDK authentication adapter (isolated source; not enabled in app)

`Authentication/SideSignAccountAdapter.swift` now calls the pinned SDK's actual
`authenticate`, `fetchAccount` and `fetchTeams` methods through a narrow injectable
portal protocol. The default adapter owns a dedicated ephemeral URLSession, no
shared cookie/cache/credential storage, 30/90-second network timeouts and a
redirect-denying delegate. System TLS verification is untouched. There is no
certificate creation/revocation, device registration or provisioning call here.

- The caller supplies fresh anisette headers from a separately consented provider;
  the adapter does not invoke the SDK's file-persisting anisette manager or pick a
  remote server. Header shape checks do not prove provider authenticity/freshness.
- Password is an in-flight argument only, not a field or storage API. String
  lifetime/zeroization cannot be guaranteed. Raw SDK/server errors are normalized
  to closed enums; account-repair callbacks always cancel instead of accepting
  agreements or opening server-supplied URLs silently.
- Login enumerates teams before producing codec-validated Keychain bytes and the
  effective expiration. Unknown/duplicate/invalid teams fail closed. Team categories
  remain the SDK's free/individual/organization types: individual/organization are
  NOT independent proof of active paid enrollment or entitlement eligibility. Do
  not blindly translate them into a paid-signing capability in the app bridge.
- Revalidation decodes with replacement anisette, fetches the account, matches its
  identity to the stored account and freshly enumerates teams. It returns prepared
  bytes, not a signing context, and does not authorize a saved team hint.
- Cancellation checks surround SDK calls and result production. The 2FA broker's
  cancellation handler unblocks its suspended SDK continuation. The future task/UI
  owner must cancel on retry, dismissal, sign-out and overall authentication timeout;
  per-request network timeouts do not bound time waiting for user input.

`SideSignTwoFactorBroker` provides a bounded single-observer challenge stream and
operation/challenge UUIDs. Stale or duplicate responses cannot consume the pending
challenge. Delivery must use a listed phone ID; verification codes are six ASCII
digits and only accepted after a delivery method. Raw retry messages are removed
(replaced with a retry flag). Phones/codes stay transient and are never logged or
persisted. There is no 2FA UI or automatic SMS/voice selection in this increment.

### Required logging privacy overlay

Pinned upstream `debugLog` in **both SideSign and AnisetteKit prints unconditionally**,
even when logging is disabled. SideSign call sites include raw failed-response
payloads; verbose paths include identity/token information. Merely invoking
`setLogging(false)` is therefore insufficient before handling real credentials.

Preparation now hash-checks those two original logging sources using
`inputs.lock.json` and applies `patches/suppress_sdk_logging.py`. The exact enum and
function shapes must match; otherwise preparation fails. Debug/verbose functions
become no-ops **without evaluating autoclosures**, logging enablement is disabled,
and explicit Anisette logging toggles only switch native logging off. Original
files and before/after hashes are retained in `UpstreamPrivacySources`/provenance;
the overlay-script hash is also recorded. Upstream copyright headers remain.

The native portal references a SideSign overlay marker which in turn references
an Anisette overlay marker: omitting either source overlay fails compilation.
This is a build-input check, not runtime evidence that native signing is available.
It does not audit every binary, third-party diagnostic path or malicious code in
the host process. These are modified AGPL library sources; corresponding-source
obligations must include the originals, overlay and build inputs on redistribution.

Three added Python overlay regressions pass. The overlay was also applied to the
actual two pinned logging sources, with hash checks and Swift grammar checks;
this is **not a full graph preparation or native build**. Eight adapter and six
broker XCTest cases use synthetic portal responses, not credentials or Apple
network access; they are written and **unexecuted**. The manual workflow includes
these sources in its library build but still does not execute native tests.

The ordinary app package graph/UI remain unchanged. The isolated bridge below now
integrates prepared results and broker events with operation guards and the actual
durable coordinator. The concrete consented HTTPS provider and isolated Keychain-backed assembly now
exist below; app promotion and native validation remain required. Resolve
native link/API/transport behavior before enabling credential collection. In
particular, cookie/redirect restrictions and SDK retry/header freshness behavior
still need real Apple/device validation; no successful login is claimed.

## SDK-to-coordinator bridge and provider consent

`SideSignAccountBridge` now owns the SDK adapter, transient flow/task/broker state,
a per-instance consent gate and one durable coordinator. Preparation copies the
**byte-identical app source** for `AppleAccountAuthenticationState`,
`AppleAccountSessionCoordinator` and `AppleAccountSessionRepository` into the
isolated target and records their SHA-256 values. Tests check those copies; no
second, handwritten coordinator model is used. Platform-specific Keychain
conformances stay in `AppleAccountCredentialStore.swift`, not the Foundation core.
This source integration does **not** mean the ordinary app links the native SDK.

- Fresh login runs provider -> SDK login/2FA -> fresh teams -> allowlisted codec ->
  operation-guarded durable commit -> explicit team choice. No password/token/code
  is sent to the provider interface, published in outcomes or put in preferences.
- Resume begins a distinct guarded operation, obtains fresh headers, validates the
  saved token/account/teams through the SDK and accepts the existing reference
  without inserting another row. The persisted team hint is not applied. Failed,
  stale, wrong-reference or signed-out resume callbacks cannot accept a session.
- 2FA phase changes before publishing a challenge; operation and challenge UUIDs
  must match on submission. Retry cancels the previous worker/broker. Sign-out
  invalidates flow generations and cancels pending work before journaled cleanup.
  A provider/SDK ignoring cancellation cannot commit a late result after the
  coordinator invalidates that operation. Actual worker retirement can be awaited
  separately; cancellation cannot force an uncooperative implementation to finish.
- The coordinator is authoritative at actor boundaries. If acceptance won a cancel
  race, the bridge reports a state change rather than pretending the saved account
  was removed. Stale callbacks never delete accepted records. UI must read the
  latest snapshot; explicitly sign out to remove an already accepted account.
- SDK individual/organization categories map to `developerProgramUnverified`, not
  verified paid membership. These contexts cannot accept provisioning results;
  active enrollment/eligibility verification is a separate pending feature.

`ConsentedAnisetteProvider` defines the credential-free interface. A concrete,
strict HTTPS header-JSON provider is now written (below), but **no default server
or on-device provider** is supplied. Its descriptor binds identity,
policy revision and optional endpoint. Remote descriptors require HTTPS with no
embedded credentials, query or fragment. Transport/TLS/storage behavior of a
future implementation still requires review; a descriptor cannot attest honesty
or prevent malicious native code using host authority.

Consent is a per-instance, in-memory, non-Codable grant with an opaque UUID and
maximum fifteen-minute lifetime. It must follow informed explicit UI approval;
the type cannot prove that action occurred. The bridge checks grant binding before
provider work, after headers, before accepting results and on 2FA submission.
Revocation/sign-out cancels pending work, and a deadline task cancels an expired
flow. Grants are never restored, automatically renewed or silently moved to a new
provider/revision. Already-sent requests or already-accepted accounts cannot be
undone by consent revocation; explicit local sign-out remains separate.

Eight synthetic bridge and four consent XCTest cases cover actual shared-core
commit/resume, explicit team choice, 2FA retry, late SDK/provider returns, consent
binding/revocation, provider failure and unverified program categories. Five new
app-coordinator XCTest cases cover guarded resume and unverified provisioning.
All **17 newly written native cases are unexecuted**. No Apple account requests,
Keychain runtime tests, native build or device tests were run. The generated smoke
package's macOS minimum is now 13 for its checked-lock test fixtures; the app/iOS
minimum is unchanged. Existing Python preparation tests pass, including shared-core
byte/hash checks. Source/grammar checks are not native typechecking.

Next: validate the concrete HTTPS provider, promote one shared backend module
without duplicate owners/types, reconcile the normal app's dependency versions,
and validate the native build/transport/keychain path before collecting credentials
or enabling the account UI. Provisioning/signing/install/refresh are still absent.

## Concrete HTTPS header-JSON anisette provider

`HTTPSAnisetteProvider` now implements the consented-provider interface for an
**explicitly configured, pre-provisioned HTTPS endpoint**. The isolated smoke
module exports `anisetteProviderFactory(descriptor:)`; constructing it makes no
request. Use it through the consent-gated bridge, not as a UI bypass. There is no
chosen public service, server discovery, HTTP downgrade, retry to another host,
v3 WebSocket/ADI provisioning, filesystem cache or on-device VM implementation.
This is deliberately a narrow dialect, not a claim of arbitrary server compatibility.

The endpoint must return HTTP 200 and `application/json`, with exactly these
case-insensitive JSON keys and **string** values:

```
X-Apple-I-MD-M       X-Apple-I-MD          X-Apple-I-MD-LU
X-Apple-I-MD-RINFO   X-Mme-Device-Id       X-Apple-I-SRL-NO
X-MMe-Client-Info    User-Agent            X-Apple-I-Client-Time
X-Apple-Locale      X-Apple-I-TimeZone
```

Unknown/missing fields, exact or case-insensitive duplicate keys, non-string or
nested values, malformed JSON/escapes, blank/control-bearing/oversized values,
invalid base64 machine/OTP values, invalid device UUIDs and nondecimal routing
info fail closed. A small flat-object parser detects duplicate keys *before*
Foundation dictionary decoding could discard them; JSONDecoder validates each
quoted string's escapes/Unicode. No payload appears in thrown error descriptions.

Client time must parse as ISO-8601 and be within five minutes of the local clock.
This is a replay/staleness sanity check, **not cryptographic proof of freshness or
provider authenticity**. The provider supplies an anisette virtual-device ID; the
request does not send the user's physical iPhone UDID. Actual Apple authentication
must still validate the returned material, and device/provider clock compatibility
must be checked natively.

The system transport owns an ephemeral URLSession with no cookies, credentials
or URL cache; it sends a fixed GET/Accept/User-Agent and cache-control headers, no
Apple ID/password/portal token/2FA response/provisioning body or device identifier.
It denies all redirects, leaves system TLS evaluation untouched and uses 20/45-
second request/resource timeouts. No TLS exception or certificate trust bypass is
introduced. The response is consumed with `URLSession.bytes(for:)`, capped at
64 KiB while accumulating decoded bytes, and its data task is cancelled on every
exit. Declared oversized lengths are rejected before reading. This bounds the
application body buffer, not every OS/network prefetch allocation. The parser also
caps header count and individual field sizes. Transport/parser failures normalize
to closed errors instead of forwarding raw responses, URLs or NSError payloads.

Twelve new synthetic-response XCTest cases cover the dialect, size/freshness,
duplicate/malformed fields, response metadata, cancellation and failure privacy.
They are **written, not run**. The default URLSession path has not been exercised
against a real server, TLS/redirect cases or an iOS device. The public Apple SDK
interface was inspected for the streaming API/data-task cancellation property;
that source check is not native compilation. A new preparation regression checks
that the provider/factory/tests enter the generated graph; the preparation
regressions pass alongside existing `make verify` checks.

The normal application dependency graph and unavailable-account UI remain
unchanged. The backend is now assembled in the isolated graph below. Next
reconcile package versions and promote/validate that path before collecting credentials. Certificate import crash, primary-host runtime and native account
provisioning/signing/install/refresh remain unresolved or unimplemented as noted
elsewhere; this provider does not solve them.


## Concrete Keychain-backed backend assembly (source only)

`NativeAccountBackend` now constructs the actual SDK adapter, explicit HTTPS
provider, lifecycle bridge, credential store and durable resume journal. The
exported smoke factory references this API. Preparation copies **six actual app
sources byte-for-byte** (three core, three storage/runtime policy), alongside the
native sources/tests; the generated package now records **22 provenance inputs**.
The two stores no longer need NimbleExtensions or the experimental runtime.
Their Foundation localization keeps the original main-bundle keys/formatting;
the guest compatibility flag remains `VexSignEmbeddedGuest`, not a security boundary.

The public actor exposes informed transient consent, authentication/revalidation,
2FA replies, explicit team selection, narrow sign-out/deletion retries, bounded
single-observer events and non-secret projected snapshots. No SDK sessions, token
bytes or Keychain references are exposed by this facade. Events are hints;
snapshots are authoritative. SDK organization/individual teams remain unverified,
not paid-enrollment proof. This is account authentication assembly, **not yet a
provisioning/signing/install/refresh backend**.

A process/module-local namespace lease excludes a second supported factory owner.
The bridge retains the lease for its full lifetime, including cancelled workers
that ignore cancellation. `shutdown()` permanently closes new work, revokes
consent, invalidates setup and terminates observation; it does **not** erase an
accepted account. Sign out first to request deletion. Release the closed facade
before opening another owner; old workers can keep the namespace busy longer.
The registry does not lock other processes, independently loaded module copies,
legacy/direct store writers or hosted native code. Promotion must enforce one
writer across the actual app's supported entry points.

Eight new facade/projection/ownership tests and two bridge shutdown/lifetime cases
are **written, not executed**. Constructor tests use the actual system-session
constructors but no account credentials, Keychain operations or requests. Other
bridge tests use in-memory stores/synthetic SDK responses; real Keychain remains
a native/device acceptance gate. Lightweight preparation checks do not compile Swift.

**Confirmed app dependency blocker:** exactly pinned Vapor 4.104.0 excludes Crypto
4.x in both its root and Swift-5.9 manifests; the isolated graph requires 4.3.1.
See [`NATIVE_DEPENDENCY_RECONCILIATION.md`](../docs/NATIVE_DEPENDENCY_RECONCILIATION.md)
and `app-dependency-review.json`. No app pins were changed or account UI enabled.

## Vapor/Crypto migration candidate

A separate disposable `ServerCompatibility` package now stages stable Vapor
4.122.3 with Crypto 4.3.1 and ASN1 1.6.0, plus the app's NIO/NIOSSL versions.
The real installer/web manager share `ServerApplicationFactory`; that same file
is copied byte-identically into this candidate target. Preparation and resolved
source verification are in `prepare_server_compatibility.py`; the native smoke
workflow's new `server_compatibility` input is manual and default-off.

Eight Python regressions cover staging/guard behavior. Four configuration/Crypto
native cases are written, not run. No SwiftPM candidate resolution, native build,
TLS handshake or workflow dispatch occurred. See the commands/API review and
limits in [`NATIVE_DEPENDENCY_RECONCILIATION.md`](../docs/NATIVE_DEPENDENCY_RECONCILIATION.md).
App pins remain unchanged; this is not yet full app/SDK graph reconciliation.

## Combined app-dependency and SDK preparation

`prepare_combined_smoke.py` now stages all **42** baseline remote package versions
with the three proposed Vapor/Crypto/ASN1 updates, the app's local package products,
actual backend/server sources and privacy-patched SDK. Shared SDK Crypto/ASN1/
OpenSSL declarations use the same remote identities as the app constraints; they
are not local solver overrides. Nine new regressions cover generation and guards.

Full **source preparation succeeded** in ignored `.build/combined-signing-smoke-v3`.
This is the first completed full locked SDK source preparation, not just a logging
patch fixture. No SwiftPM resolution, native build or requests to Apple occurred.
The manual workflow's default-off `combined_dependencies` option stages/resolves/
verifies this graph only; its existing isolated build is not a combined build.
See the combined-gate section of the reconciliation document for commands and
scope. The real app still does not link this SDK or collect account credentials.

## Free-account provisioning preflight (coding phase)

The concrete backend now exposes `provisioningPreflight(contextID:request:consent:)`.
It is **read-only portal inventory and planning**, not yet a provisioning executor.
The actual coordinator grants session bytes internally only for a selected,
non-expired free-account context whose durable Keychain reference still matches.
No session bytes/references leave the public facade. Paid SDK category guesses
remain blocked; the existing imported-certificate path is separate and unchanged.

The worker obtains fresh consent-bound headers, revalidates account identity and
team with the actual hardened SDK portal, then reads device/AppID/certificate
inventory. Every SDK hop is followed by cancellation, context-generation, expiry
and consent checks. Sign-out/shutdown/revocation cancel the worker and invalidate
its generation; the bridge retains the namespace lease until actual retirement.
Busy preflight blocks a competing authentication flow. Caller cancellation is
forwarded to the retained worker; an uncooperative transport can delay retirement,
so do not block UI dismissal on it. Existing system TLS/redirect/cookie policies
are reused, not replaced by DeveloperPortal.shared or a second portal transport.

Requests require an explicitly supplied legacy/modern UDID and 1–32 unique exact
bundle identifiers. The 32 cap is a local work bound, **not an Apple quota**.
The request's ordinary string/debug descriptions are redacted. Physical UDID is
only compared locally in this read-only step and is never passed to the anisette
provider. Device names, other registered UDIDs, raw certificates and credentials
are not returned in plans. Unknown/disabled matching devices, duplicate records,
case-colliding AppIDs, unsupported membership and expired matching AppIDs fail
closed. Inventory caps apply **after SDK decoding**, not as a network-memory bound.
Wildcard AppID inventory is not supported by this conservative first pass.

Plans are non-Codable, context-bound previews valid at most 120 seconds and no
longer than session/matching AppID expiry. They list missing registrations and
profile work but are not executable approvals. A remote certificate count never
proves possession of a corresponding private key; profiles are not treated as
usable without independent CMS/certificate/device/entitlement validation.

**Important next coding work:** durable device-only CSR/private-key ownership and
mutation reconciliation before certificate creation. The SDK's convenience
`addCertificate` generates a private key and submits the CSR internally; calling
it directly would lose ownership/reconciliation information on cancellation or an
ambiguous response. This increment intentionally does not call it, automatically
revoke another certificate, register devices/AppIDs or create profiles. After that
come controlled mutations, profile validation, signing/install/refresh integration,
and finally account UI promotion. Coding is **not finished end-to-end**.

Five native plan cases and a preparation-registration regression were written for
later execution. Per the user's coding-first decision, no tests, native builds or
GitHub Actions workflows were run in this increment. Only static source grammar
and diff checks were performed. Preparation now registers **25 provenance inputs**;
old generated directories are stale snapshots and must not be reused as proof of
this new code. Normal account UI stays unavailable.

## Durable signing-identity ownership (coding phase)

`prepareSigningIdentity(contextID:)` now prepares or recovers an account/team's
local signing key and CSR. The public result contains only operation ID, team,
phase and public-key/CSR hashes. `discardPreparedSigningIdentity` removes only a
never-submitted draft by exact operation ID. No CSR/private-key export is public.
Both use the selected free-account context and authorized durable session row;
the codec derives a stable owner binding without inventing anisette headers or
exposing account identifiers. Ownership survives session renewal/re-login for the
same account/DSID/team. The label is SHA-256 of a versioned, length-delimited scope,
not encryption or an independent authentication mechanism.

### Key/CSR creation and storage

- Apple Security generates a software RSA-2048 key in memory, not a permanent
  Security key item or Secure Enclave key. A minimal PKCS#10 CSR uses the random
  operation machine name as CN, with RSA/SHA-256 signature and SPKI public key.
- One atomic generic-password blob per owner stores key DER, CSR DER, public key,
  operation ID, phase and optional certificate in the separate
  `com.vexsign.native-signing.identities.v1` service. Rows are **WhenUnlocked / This
  Device Only**, non-synchronizing, with no shared access group or preferences/file
  fallback. Record size is bounded to 256 KiB; individual key/CSR/certificate fields
  have smaller caps. Read prompts are disabled with LAContext.
- Load/write validates schema/owner/shape and reconstructs the public key and
  deterministic PKCS#1-v1.5 CSR from the stored private key. Mismatches, corruption,
  locked storage and unknown versions do not become an empty vault or a new key.
  Raw errors/records are not logged; record string/debug descriptions are redacted.
- Software keys and Swift Data/SecKey copies cannot be promised to zeroize. These
  storage policies do not isolate secrets from malicious code with host-process
  authority; embedded guest compatibility guards are not an OS security boundary.

### Durable intent and uncertain outcome handling

The internal identity coordinator has these forward-only transitions:

```
prepared -> submissionUncertain -> certificateRecorded
```

`beginSubmission` atomically persists `submissionUncertain` **before** returning
CSR-only material to a future portal executor. Keychain updates condition on both
operation UUID and expected prior phase. There is no upsert/reset-on-failure or
"retry CSR" transition. Cancellation after the marker, network failure, missing
response or failure to save a certificate must leave the key and marker recoverable.
Deletion similarly requires the matching UUID and persisted `prepared` phase;
a stale draft cannot delete a row that advanced to uncertain.

Reconciliation matches an observed certificate's exact SPKI to the owned key.
Zero matches may be eventual consistency; multiple matches may be duplicate issue.
Neither permits another submit, arbitrary adoption or automatic revocation. Only
one match can advance the row after key/team/validity checks. A recorded certificate
is still **not** proof of Apple chain trust, certificate purpose/revocation,
entitlement eligibility, a valid CMS profile or signing readiness. Those validators
and real portal acquisition of the observations remain later coding work.

Key preparation and deletion run through retained bridge workers, with competing
account/provisioning work gated. Revocation/sign-out/shutdown cancel these workers;
the namespace lease remains held until they retire. A key persisted just before
cancellation/context loss is retained and recovered on a later authorized retry.
**Sign-out deletes the authentication session, not signing-identity rows**, and
never revokes a portal certificate. Draft deletion is separate. Explicit disposal/
rotation of submitted or certified identities, including user-facing warnings,
is still pending; there is no destructive broad-purge API.

### Integration limits and next coding step

This increment does **not** submit a CSR to Apple. The SDK's `addCertificate`
convenience method must not be used: it would generate another key outside this
vault. Its lower-level request dispatcher is module-internal, so the next step
needs a reviewed, pinned CSR-supplied submission adapter/overlay that preserves
transport/privacy protections and does not automatically retry a mutation.
Then wire fresh account/team authority, reconciliation, controlled AppID/device/
profile operations, profile/trust validation, signing/install/refresh and account
UI promotion. The ordinary app remains `notIntegrated`; end-to-end coding is not
finished, and old prepared graph snapshots are stale.

Ten native fixtures cover retry/restart, durable intent, failed intent writes,
protected deletion, wrong operations, rejected certificates, empty reconciliation,
owner separation, in-memory RSA/CSR integrity and Keychain query policy/corruption.
They are **written, not executed**. The synthetic state-store fixtures do not prove
cryptography or real Security behavior; separate in-memory crypto cases are also
unrun, and no case uses the real Keychain or Apple portal. A new preparation
registration regression is written; current preparation registers **29 provenance
inputs**. Per coding-first direction, no tests, builds, Actions runs, real key
creation, Keychain writes or Apple requests were performed. Static grammar,
Python syntax and diff checks only.

## CSR-supplied certificate submission and recovery (coding phase)

The isolated backend now wires the saved CSR to a real certificate-submission
boundary. The supported sequence is:

1. `prepareSigningIdentity` creates/recovers the device-only key/CSR.
2. After an informed user action, `recordExplicitCertificateCreationApproval`
   grants **one** attempted creation for the exact selected context/identity.
   This is separate from anisette-provider consent, non-Codable, revocable,
   bounded to 120 seconds, and never restored/renewed/minted at launch.
3. `createDevelopmentSigningCertificate` consumes that approval, obtains fresh
   consent-bound anisette headers and revalidates account identity/team with
   Apple. Only the selected free team is eligible; paid SDK guesses remain blocked.
4. The vault must atomically advance the saved key/CSR to `submissionUncertain`
   before CSR material can reach the portal. Context, consent, approval and task
   cancellation are checked again before sending.
5. A direct receipt is adopted only after private-key/SPKI, team and validity
   checks. A successful reply without certificate bytes/ID enters read-only
   inventory reconciliation. No fallback to another key or CSR send exists.

The public API returns metadata tickets, not certificate/session/key/CSR bytes.
A separate `reconcileUncertainSigningCertificate` entry point revalidates fresh
account/team authority and reads certificate inventory; it **cannot submit a CSR**.
Empty/ambiguous inventory remains uncertain. No error, timeout, quota rejection,
sign-out or cancellation automatically resets intent, rotates keys or revokes an
existing certificate. Reconcile an uncertain attempt instead of issuing again.
A local commit may win a cancellation race; re-read the owned ticket rather than
assuming a cancelled/failed call guarantees no certificate was created/recorded.

`revokeCertificateCreationApproval` invalidates even pending approval issuance
through an epoch and cancels in-flight certificate work. General sign-out,
shutdown and provider-consent revocation also invalidate/cancel it. Workers have
consent/approval deadlines, are mutually gated against other account work, and
retain the namespace lease through actual retirement. Cancelling a request is
**not** a guarantee the server did not perform the mutation.

### Pinned SDK addition, not generate-and-submit

`patches/VexSignPreparedCSR.swift` is installed as an additional source file in
the pinned SideSign module because its existing low-level dispatcher is internal.
Preparation hashes the added source and the reviewed original dispatcher/constants,
refuses an existing destination/unreviewed upstream changes, and records the overlay
in provenance. Source/AGPL modification notices must accompany distribution.
The existing logging-suppression overlays remain mandatory.

The new method:

- Receives the **already saved CSR**, never generates a key and never calls the
  SDK `addCertificate` convenience method.
- Uses a fixed Apple HTTPS development-CSR endpoint through the native portal's
  existing ephemeral, redirect-denying, system-TLS URLSession. No arbitrary URL,
  signer, cookie/credential store or TLS trust bypass is introduced.
- Makes one **application-level** URLSession send, with no retry/failover/revocation
  loop. Its request/machine UUID is correlation metadata, **not an Apple
  idempotency guarantee**; URLSession/server-level behavior still needs validation.
- Accepts only HTTP 200 at the exact request URL and a decoded explicit success
  result. The accumulated streamed mutation-response body is capped at 256 KiB;
  direct certificate bytes are capped at 64 KiB. These do not bound all OS buffers
  or the older SDK's separate inventory/authentication response allocations.
- Does not log raw requests, headers, bodies, CSR receipts or transport errors;
  failures become fixed safe errors. `certRequestId` is never guessed to be a
  certificate ID. Unsupported response dialects remain uncertain rather than
  prompting another send.

This is **source wiring only**, not a successfully issued/trusted certificate.
Apple endpoint/dialect/CSR acceptance, Security/Keychain behavior, deadlines,
transport/replay behavior and native compilation remain unvalidated. Trust-chain,
certificate-purpose/revocation, CMS/profile and entitlement validators are still
required before signing. Normal VexSign app account UI/availability and app package
pins are unchanged. Device/AppID/profile mutation wiring, signing/install/refresh,
app promotion and primary-host runtime integration remain unfinished.

Six new native fixtures cover separate mutation approval, intent-before-send,
missing-receipt inventory fallback, failed-send retention, read-only recovery,
revocation and bounded approval lifetime (some cases combine assertions). Their
fake vault deliberately does not prove certificate cryptography or real Keychain
semantics. Three new preparation regressions are written for overlay registration,
hash guarding and overwrite rejection. **None were executed**. Preparation now
registers **32 first-party provenance inputs** plus the separately tracked SDK CSR
source addition. Old generated directories are stale; prepare afresh during the
user's later GitHub Actions testing phase. Only static grammar/Python syntax/diff
checks ran; no native build, real CSR request, Keychain mutation, key generation,
workflow dispatch, commit or push was performed.

## Profile acceptance boundary (coding continuation)

`Provisioning/NativeProvisioningProfileValidator.swift` adds the conservative
**basic free-account iOS development** profile policy. It is internal and not
connected to the normal app's signing UI or portal mutation buttons.

The owned-identity actor can now project a read-only validation request only from
an exact UUID/owner row in `certificateRecorded`. It rechecks row shape, saved
private key/public key/CSR binding, certificate SPKI/team and current certificate
validity. Prepared/uncertain/corrupted rows cannot supply certificate evidence.
Projection never generates another key, exports a private key, changes a row or
contacts Apple. State-only fake vaults inherit a fail-closed projection default.

Profile constraints require:

- Exact selected team and free-account App ID prefix, an explicit bundle ID (not
  a wildcard), and the expected profile UUID when one is supplied.
- Current finite creation/expiration dates, iOS-only platform, explicit target
  UDID membership and an exact DER match to the owned certificate. Device/cert
  lists are capped and duplicate entries are rejected.
- Development `get-task-allow` as a real Boolean, not a numeric/string surrogate;
  no enterprise/all-device or App Store profile substitution.
- A deliberately narrow entitlement allowlist. Unsupported push/iCloud/app-group
  capabilities are rejected rather than silently dropped or granted. A profile's
  team-wide keychain wildcard is narrowed to the exact app group in the result;
  it is not copied into signing entitlements. This is not yet validation of the
  IPA's own requested entitlements or nested executables.

**Parsing is not CMS verification.** The plaintext policy result is a distinct
constraint-summary type and cannot construct the authenticated-profile type.
The CMS gate accepts only an explicit verifier satisfying Apple-authorized
provisioning-signer chain/purpose, signed attributes and content-digest checks.
There is **no production CMS verifier yet**: the default returns
`cmsVerificationUnavailable`, including for a perfectly matching plaintext plist.
No certificate embedded in a profile is automatically a trusted anchor, and a
successful TLS connection is not proof of a valid profile signature.

CMS input is capped at 1 MiB, extracted payload input at 512 KiB and each
certificate at 64 KiB; these are input/collection bounds, not a bound on all parser
or verifier allocations. Errors are fixed and descriptions redact profile/device
material. The validated output records the exact CMS hash, but is still NOT proof
of certificate chain/purpose/revocation or signing/install readiness. Execution
must separately recheck live account context, deadlines, target and IPA contents.

Fourteen synthetic profile cases, two additional identity-projection cases and
one preparation-registration regression are written, **not executed**. Mock CMS
verification and synthetic certificate bytes are explicitly fixture-only, not
cryptographic/trust evidence. Preparation now registers **34 first-party inputs**
plus the separately tracked SDK CSR addition; existing generated directories are
stale. Static Swift grammar, Python syntax and diff checks only. No build/test,
Actions run, Apple operation, actual key generation or Keychain mutation occurred.
Device/AppID/profile mutation executors, a real Apple CMS verifier, certificate
trust/purpose validation, signing/install/refresh and primary-host integration
remain unfinished; app availability stays `notIntegrated`.

## Controlled registration core (coding continuation)

`NativeRegistrationExecutor` adds an internal, single-subject device/App ID
registration state machine. It is **not connected to a production SDK portal or
normal app UI yet**, and does not create profiles or enable account signing.

- Explicit, exact-context/owner/subject approval is non-Codable, single-use,
  revocable and limited to 120 seconds. Anisette consent is not mutation approval.
  Known journal rows require reconciliation, not a new creation grant.
- The portal contract requires fresh account/free-team revalidation. Execution
  checks current authority between hops, reads inventory first, and revalidates
  before persisting a new uncertain intent. Only then can `registerOnce` run.
- Fresh inventory must uniquely match the exact enabled subject and not be
  expired. Ambiguity, case-conflicting bundles, disabled/invalid records and
  duplicate remote IDs fail closed. Pre-existing registrations do not send a
  mutation or manufacture a local operation ID.
- An uncertain intent is add-only. Successful observation conditionally advances
  it to recorded; failed persistence prevents sending. Transport/commit failures,
  cancellation, empty inventory or loss of an already recorded remote item never
  clear/reset a row or authorize automatic recreation. The separate recovery
  method contains no registration call. Audited renewal/rotation for expired
  registrations remains a future policy, not a hidden journal deletion.
- Both logical resource hashes fold case, preventing a differently cased bundle
  request from bypassing uncertain intent. Approval hashes retain exact bundle
  spelling. Device identifiers are explicitly supplied and normalized, never
  inferred from vendor/advertising IDs or forwarded to anisette providers.
- Workers have a retained exclusive task, caller cancellation/revocation, and a
  deadline capped by supplied authority expiry, approval expiry and 900 seconds.
  Future bridge integration must supply the real consent/session expiry, validate
  owner/context bindings and share its existing account-work gate/namespace lease.
  Uncooperative work retains its slot until retirement; cancellation is not proof
  that Apple did not perform the mutation.

`NativeRegistrationKeychainStore` supplies the device-only durable journal:
`com.vexsign.native-signing.registrations.v1`, no sync/shared access group/fallback,
noninteractive reads, 4 KiB maximum records, and UUID + uncertain-phase conditional
commit. Only not-found means absent. Raw UDIDs/bundles/remote IDs are not serialized:
owner, subject and observed remote identifiers are hashed (not encrypted). No
credentials, anisette headers or private key enter this journal. There is no
reset/delete/automatic quota cleanup interface.

Thirteen native fixtures and one source-registration regression are written,
**not executed**. Fixtures use fake portal/storage and a fake Keychain client;
they do not validate Apple's registration APIs or actual Keychain behavior.
Preparation now registers **37 first-party inputs**. Only static Swift grammar,
Python syntax and diff checks ran. No native build/test, Apple call, key generation,
Keychain mutation or Actions run occurred. The temporary grammar-tool directory
was absent in this workspace snapshot and was reinstalled for the syntax check.

Remaining production blockers: reviewed bounded SDK device/App ID transport
adapters, shared native bridge approval/lease integration, profile creation and
its uncertainty handling, actual Apple CMS verification, certificate trust/purpose,
IPA entitlement validation, signing/install/refresh and primary-host integration.
App availability is unchanged (`notIntegrated`). One application-level send is
not a server/URLSession exactly-once guarantee; uncertainty is deliberately kept.

## Reviewed registration transport and account-bound adapter (coding continuation)

The pinned SideSign device/App ID actions, dispatcher, constants and model defaults
were source-reviewed at the existing immutable revision. `patches/VexSignRegistration.swift`
now adds narrow register/list methods to that module. Preparation verifies hashes
for all six reviewed originals and the added source, refuses overwrites/drift and
records the addition separately in provenance. AGPL source/modification notices
remain distribution requirements; no upstream or app package pins changed.

The transport uses the native portal's existing ephemeral, redirect-denying,
system-TLS session and fixed Apple HTTPS action allowlist. It bypasses the SDK's
permissive dispatcher and registration convenience methods. It sends one
application request with the **journal intent UUID** for correlation (not server
idempotency), has no cleanup/retry/failover, requires exact-URL HTTP 200 and explicit
success status, rejects nonempty error arrays, and sanitizes errors without raw
logging. Mutation-response accumulation is capped at 256 KiB and inventory at
1 MiB/1,000 records. These are not bounds on all OS/parser allocations.

Inventory arrays/identity fields are required, not defaulted to empty/guessed
values. Device class/status must be explicit: only known enabled iPhone/iPad
records qualify; unknown status dialects remain blocked. App ID expiry is parsed
as a plist Date or ISO-8601 JSON date, not guessed from ambiguous numeric epochs.
Missing/expired lifetime cannot prove an enabled free-account App ID. Unrelated
wildcard App IDs may appear in inventory but cannot satisfy an explicit request.
Case aliases are preserved for executor rejection; duplicates remain errors.

`SideSignBoundRegistrationPortal` connects this transport to the executor protocol:
it binds the encoded session to an exact owner/context, requires explicit live
consent/context callbacks and authority expiry, retains a supplied account lifetime,
obtains fresh argument-free anisette headers, and revalidates account/free team.
Authorization is transient (at most 30 seconds/session/authority expiry), invalidated
before revalidation and protected against late callback replacement. The existing
read-only certificate adapter's generic constraint was widened to the read-only
portal protocol so its fresh-authority helper can be reused without adding CSR
creation authority to registration. No private key or target identifier is sent
to the anisette provider by this adapter.

**The shared account bridge/public facade/UI are not yet wired to registration.**
They must supply the real namespace lease, shared busy/cancellation gate, consent
expiry and exact live context callback, and avoid retained-service callback cycles.
This source adapter is not a validated Apple transaction or app signing capability.
Actual wire/status/date dialects, HTTP behavior, replay, lease integration and
native API compilation still require the later testing phase. CMS/profile creation,
certificate trust/purpose and signing/install/refresh remain blocked/unimplemented.

Seven new native DTO/inventory-policy cases and two preparation regressions are
written, not executed. They do not exercise real HTTP/TLS/Apple mutation or prove
the new bound adapter's runtime behavior. Current preparation registers **40
first-party inputs**, plus the CSR and registration SDK additions tracked separately.
Fresh preparation is required; old generated directories are stale. Static Swift
grammar/Python syntax/diff checks only; no build, test, Apple request, key generation,
Keychain mutation, Actions dispatch, commit or push occurred. `notIntegrated` is unchanged.

## Registration facade/bridge wiring (coding continuation)

The isolated `NativeAccountBackend` now exposes explicit registration approval,
registration execution, approval revocation and separate read-only recovery:

- `recordExplicitRegistrationApproval(contextID:subject:lifetime:)`
- `registerAccountResource(contextID:subject:approval:consent:)`
- `revokeRegistrationApproval()`
- `reconcileAccountRegistration(contextID:subject:consent:)`

`NativeRegistrationSubject` has an explicit device/App ID constructor and redacted
printing; its raw value remains module-internal. Public results expose the optional
local operation UUID, not raw portal/device identifiers. Opaque user approval is
non-Codable and binds exact context, stable owner, exact target spelling, bridge
generation, revocation epoch and expiry (at most 120 seconds). No anisette consent
or read-only plan can manufacture it. Known journal rows must be reconciled.

The bridge now gates authentication, preflight, identity and certificate work
against a retained registration task. Approval setup reserves the same setup gate.
Sign-out, shutdown and anisette-consent revocation cancel registration and invalidate
pending grants; explicit registration revocation does so without signing out.
Cancelled/uncooperative work holds the slot and namespace lifetime until actual
retirement. Sign-out does **not** erase registration/identity journals, revoke a
certificate or undo an Apple operation.

Each worker constructs a short-lived account-bound portal with the real factory
namespace lease, selected context/session, live generation/consent checks and the
minimum session/consent expiry. Fresh anisette retrieval has no target/account
arguments. No persistent bridge/service callback cycle is introduced: bound portal
and executor are local to the retained worker. Internal executor approval delegates
only the **remaining lifetime** of an already consumed user grant; it never extends
or independently renews user authority. Outer and executor deadlines/cancellation
cover setup and remote work. Durable intent still precedes the sole registration
send, and all ambiguous outcomes preserve read-only recovery instead of reissuing.
A completed commit can win a cancellation race; a failed/cancelled API call does
not prove that nothing happened remotely or that no local observation was stored.

Seven additional bridge fixtures and one preparation-registration regression are
written/unrun. They use fake session stores, journal, portal and lifetime; paused
registration exercises the shared busy gate and cancelled-worker retirement, not
real Keychain or real namespace-lease exclusion. Current preparation registers
**41 first-party inputs** plus two separately tracked SDK additions. Only static
Swift grammar, Python syntax and diff checks ran. No native build/test, Apple
request, key generation, Keychain operation, Actions dispatch, commit or push.

This exposes an isolated backend API, **not normal app/UI promotion or successful
Apple registration**. Native API compilation, wire dialects, cancellation and
actual Keychain/namespace behavior still require the deferred testing phase.
Profile creation with durable uncertainty, real Apple CMS verification, certificate
trust/purpose/revocation, IPA/nested entitlement validation, signing/install/refresh
and primary-host runtime integration remain unfinished. `notIntegrated` is unchanged.

## Durable profile creation core (coding continuation)

`NativeProfileCreation*` adds an **internal, not production-wired** limited
one-App-ID/one-device/one-certificate profile creation and recovery core. The pinned
SDK profile action source was reviewed for its explicit resource-ID requirements;
its permissive create/regenerate/update convenience methods are not invoked.
No profile network adapter is selected in this increment.

The request binds identity UUID, team, exact bundle/device and certificate bytes,
plus freshly resolved remote App ID/device/certificate IDs. A future bridge must
obtain the validation request from the owned identity projection and independently
validate every remote binding, not accept caller-supplied ownership assertions.
Canonical length-delimited logical-target hashes fold bundle case and exclude
remote-ID aliases, so changing an alias cannot evade pending intent. Exact approval
hashes additionally bind original spelling, all remote IDs and a selected profile
UUID when present. Neither requests nor approvals are persisted/exported publicly.

Creation requires explicit, non-Codable, single-use approval (at most 120 seconds),
fresh authority checks/inventory and durable add-only uncertain intent before the
one application-level create call. The request UUID is correlation, not a server
idempotency guarantee. Recovery never creates, updates, regenerates or deletes.
Empty/mismatched/ambiguous inventory, timeouts, bad profiles and storage failures
never reset intent. Recorded remote/CMS/UUID changes also require reconciliation,
not silent adoption or automatic regeneration. Audited expiry renewal/rotation is
still a separate future policy, not journal deletion.

**A real CMS verifier is still absent.** The default executor fails with
`cmsVerificationUnavailable` before approval/store/portal I/O. With an explicitly
injected verifier, every targeted inventory envelope must pass CMS authentication
and exact profile constraints before adoption/commit; conflicting or invalid
entries block both adoption and new creation. Mock verification exists only in
fixtures. Inventory caps are 50 envelopes, 1 MiB each and 4 MiB aggregate at this
boundary, not a promise about all upstream allocations or transport buffering.
Authority/approval expiry, cancellation, revocation and retained worker exclusion
mirror the registration core; caller bridge/lease integration is not yet supplied.

Authenticated profile output now retains the **exact original CMS bytes**, internally
and with redacted printing, for future embedding. It does not reconstruct an unsigned
plist. This remains separate from certificate trust/purpose/revocation, IPA/nested
entitlement checks and final signing/install authorization.

`NativeProfileCreationKeychainStore` journals only owner/target/remote-ID hashes,
operation UUID, phase, observed CMS hash and profile UUID under
`com.vexsign.native-signing.profiles.v1`. It does not persist CMS, raw UDIDs/bundles,
credentials or keys. Rows are device-only/non-sync/noninteractive, capped at 4 KiB;
forward commit requires matching UUID and uncertain phase. Only not-found means
absent; malformed/locked storage cannot trigger a new creation. No reset/delete API.

Ten new synthetic profile-creation/Keychain-client fixtures and one preparation
regression are written/unrun. They do not prove CMS cryptography, real Keychain or
Apple profile issuance. Current preparation registers **45 first-party inputs**
plus the two SDK source additions. A source-edit grammar issue was fixed; final
static grammar/Python syntax/diff checks passed. No native compile/build/test,
actual CMS verification, Apple request, key generation, Keychain operation, Actions
dispatch, commit or push occurred. Normal app availability remains `notIntegrated`.

Remaining coding: reviewed bounded profile transport, real Apple-authorized CMS
verification, shared bridge/facade approval and owned-resource resolution, renewal
policy, certificate and IPA validation, signing/install/refresh, UI promotion and
primary-host runtime integration. Finish coding before the requested native/Actions
validation phase; do not treat these static checks as a native acceptance result.

## Bounded profile transport (coding continuation)

`patches/VexSignProfiles.swift` adds separate explicit-ID list/download and limited
profile creation calls to pinned SideSign. Source review confirmed a critical
boundary: the SDK's **app-based download can generate a team profile**. This path
never calls it, update/regenerate, or automatic cleanup. Download uses only the
reviewed manual `downloadProvisioningProfile.action` with an exact profile ID.
Creation fixes distribution to `limited`, exactly one certificate/device/App ID,
and journals' operation UUID correlation; there is no distribution/wildcard option.

The existing SDK registration overlay now supplies a module-internal shared
bounded transport for an explicit seven-action allowlist, with typed array/bool
parameters. It retains exact Apple HTTPS endpoints, the native private ephemeral
redirect-denying/system-TLS session, strict HTTP 200/success/error handling,
cancellation checks, cookie/cache suppression and sanitized errors. No application
retry/failover or server idempotency claim. Creation/download response accumulation
is capped at 2 MiB (base64 CMS overhead), listing at 1 MiB; extracted CMS is limited
to 1 MiB each and 4 MiB aggregate. These do not bound every parser/OS allocation.

Listing requires an actual profile array and explicit ID/UUID/App ID bindings;
missing fields cannot mean empty inventory. Known pagination markers or inconsistent
counts fail closed instead of truncating. Completeness against actual Apple API
pagination/dialects still needs native/service validation before production use.
The native wrapper checks live authority between every list/download hop, preserves
partial failures as errors, and rejects ID/UUID substitution, duplicates, bundle
case aliases or remote App ID conflicts. Unrelated wildcard entries never satisfy
an explicit request. An explicit existing profile UUID selects only that candidate
and is recovery-only: it cannot authorize creating a new arbitrary UUID.

Download/list metadata is **not CMS proof**. The core now binds the authenticated
CMS UUID to the listed/downloaded UUID before commit. Default missing CMS verifier
still prevents profile executor approval or I/O. No bound profile-creation portal,
public backend/UI promotion or real CMS verifier is selected in this increment;
transport-only methods cannot supply account/resource/ownership authority by
themselves. Production integration must resolve fresh exact owned resources and
retain the existing bridge/consent/namespace gates before using these calls.

Preparation hash-guards five reviewed original profile/dispatcher/model files,
the added profile source, and its exact shared-transport dependency. All three SDK
source additions are separately tracked; app/upstream package pins are unchanged.
AGPL source/modification notices remain required. Fresh preparation is necessary;
old generated work directories are stale.

Eight new DTO/inventory-policy cases, two core UUID-binding/recovery-only cases and
two preparation regressions are written, **not executed**. Fixtures do not exercise
real HTTP/TLS, Apple responses or CMS cryptography. Current registration is **47
first-party provenance inputs plus three SDK additions**. Static Swift grammar,
Python syntax and diff checks only; no native compile/build/tests, actual Apple
request, key generation, Keychain operation, Actions dispatch, commit or push.
Real CMS verification, bound profile portal/bridge wiring, final certificate/IPA
acceptance, renewal, signing/install/refresh and primary-host integration remain
unfinished. App availability remains `notIntegrated`.

## Account-bound profile authority and resource bindings (coding continuation)

`SideSignBoundProfilePortal` now implements the internal profile portal contract.
It is **not yet assembled by the public backend**. Construction requires a CMS
verifier, exact encoded-session owner/context, explicit authority expiry, real
account lifetime and live consent/context plus owned-identity callbacks. The default
missing verifier fails before session decoding or any callback/I/O. No plaintext
plist extraction, embedded root or TLS certificate is substituted for CMS trust.

The identity actor now projects `NativeOwnedProfileIdentity` atomically with the
recorded identity UUID, original certificate ID and target validation material.
It rechecks row shape, private/public key/CSR binding, team and current certificate
validity before returning metadata/public certificate material. The previous
validation-request projection delegates to this same implementation. State-only
identity fakes inherit a fail-closed projection default, not fabricated ownership.
No new key, key export, Keychain write or portal call is part of this projection.

Before authorizing profile inventory/creation, the bound adapter:

- Obtains argument-free fresh anisette headers and revalidates account/free team.
- Re-reads the owned projection around asynchronous work and matches exact
  identity UUID, certificate ID/DER, team, bundle and explicit device.
- Reads enabled exact device/App ID registrations, verifies the corresponding
  remote IDs, and requires a current explicit App ID lifetime. Missing, disabled,
  case-conflicting, duplicate or aliased resources cannot authorize creation.
- Requires a unique exact owned certificate ID **and** certificate DER in fresh
  certificate inventory; the same bytes under multiple IDs are ambiguous.
- Retains an invalidatable, nonce-protected authorization for at most 30 seconds,
  session expiry and authority expiry, checks callbacks between profile downloads,
  and rejects existing-profile UUID selection as creation authority.

These are binding checks, not certificate chain/purpose/revocation proof. In
particular, this adapter still reads certificate inventory through the existing
read-only SDK method: count/DER limits here are **post-decode**, not HTTP/memory
bounds. That transport's permissive status handling remains a hardening task
before production promotion. The bounded device/App ID and profile methods are
unchanged. Account/team reads likewise retain the earlier SDK limitations.

The future bridge must provide the actual owned-identity actor callback, shared
busy/deadline/cancellation gate, namespace lifetime and CMS verifier, with per-worker
ownership to avoid callback cycles. Invalidating this adapter cannot promise that
an already transmitted server mutation was undone. It adds no retries, creation
fallback, regeneration, certificate revocation or cleanup. Profile approval,
intent journaling and authenticated adoption remain the executor's responsibility.

Seven resource-policy fixtures, one default-gate adapter fixture and one preparation
regression are written, **not executed**. They do not validate real certificate/CMS
cryptography, the adapter's successful runtime flow or actual lease/Keychain behavior.
Current preparation registers **50 first-party inputs** plus three SDK additions.
Static Swift grammar/Python syntax/diff checks only; no native compiler/build/tests,
actual Apple request, cryptographic verification/key generation, Keychain operation,
Actions dispatch, commit or push occurred. Normal UI stays `notIntegrated`.

Remaining: actual Apple-authorized CMS verification, strict bounded certificate
inventory, profile bridge/facade integration, full certificate/IPA acceptance,
renewal policy, signing/install/refresh and primary-host runtime integration.

## Strict profile certificate inventory (coding continuation)

The bound profile adapter no longer uses `fetchCertificates`/the legacy permissive
SDK services dispatcher. `VexSignCertificateInventory.swift` adds a read-only,
fixed `listAllDevelopmentCerts.action` path through the shared native-injected
transport: exact Apple HTTPS URL/HTTP 200, explicit success result, nonempty-error
rejection, bounded streaming and cancellation, no raw logging or automatic dialect
fallback. The shared allowlist now has eight actions, none for regeneration/cleanup.

Certificate array, actual `certificateId` and `certContent` are required. There is
no nil-to-empty default, `compactMap` dropping malformed entries, request-ID guess
or base64 decoding with ignored unknown characters. Known pagination indicators,
missing identity/material, duplicate IDs or duplicate bytes fail closed. Response
accumulation is capped at 1 MiB, collection at 1,000 records, individual material
at 64 KiB and decoded aggregate at 512 KiB; these are not all-OS/parser memory bounds.
An explicit empty array transfers as empty, but the resource gate cannot authorize
a profile without a unique exact owned certificate ID/DER match.

This uses the pinned SDK's **legacy plist action constant/schema**; its current
convenience fetch uses a different services JSON endpoint. The legacy action's
actual availability/response dialect is unvalidated, not assumed drop-in parity.
Unsupported/rejected dialects block the operation; no silent modern-endpoint retry
or fallback is added. Supporting another dialect requires separate source review,
strict status/schema/pagination and transport bounds. Other authentication/team,
preflight and certificate-recovery SDK reads retain their previously documented
limitations; this change specifically hardens the profile resource path.

Raw DTO material transfer is not DER/chain/purpose/revocation proof. The bound
adapter still rechecks the durable private/public/CSR/certificate ownership
projection, and real Apple-authorized CMS verification is still absent/default-
blocked. No certificate has been issued, verified or marked ready by this work.
Profile public backend/UI integration and final signing gates remain unfinished.

Preparation hashes four reviewed original dispatcher/constants/certificate/model
sources, the new addition and its exact shared transport dependency. The existing
profile overlay dependency hash was updated consistently; no app/upstream pins
changed. Current provenance registers **52 first-party inputs plus four SDK source
additions**. Fresh preparation is required; old generated directories are stale.

Seven DTO/material-policy fixtures and two preparation regressions are written,
**not executed**. They do not test HTTP/TLS, actual Apple schemas/pagination or
cryptography. Static Swift grammar, Python syntax and diff checks passed. No native
compiler/build/test, Apple request, Keychain operation, key generation, Actions
dispatch, commit or push occurred. App availability stays `notIntegrated`.
Remaining coding includes real CMS verification, profile facade/bridge assembly,
certificate trust/purpose/revocation, IPA/nested entitlements, renewal policy,
signing/install/refresh and primary-host runtime integration.

## Apple-profile CMS verifier implementation (coding continuation)

A concrete `NativeAppleProfileCMSVerifier` is now written using **public Security
APIs and CryptoKit**, with no private CMS policy SPI, OpenSSL bridge or package-pin
change. It is **not compiled, executed, validated against a real Apple CMS fixture,
or selected by default**. `NativeProvisioningProfileValidator.appleCMS()` is an
explicit internal opt-in for later assembly; ordinary/default profile operations
remain unavailable and normal app UI/capability is unchanged.

The supported first slice is attached, definite-length DER CMS SignedData v1,
exactly one issuer/serial signer, SHA-256 and RSA PKCS#1 v1.5 (2048–4096 bits).
Unsupported BER indefinite/chunked, SHA-1, ECDSA, detached, multiple signers, CRLs
and unsigned-attribute forms fail closed; this is not universal Apple profile
compatibility. The bounded reader rejects trailing/truncated/non-minimal lengths
and high tags, caps structural collections and walks nested signed attributes with
a depth/node budget. Parsed envelope output is explicitly not authenticated output.

Verification binds the signer certificate by exact issuer DER/serial, checks
mandatory unique content-type/message-digest attributes and SHA-256 of the exact
encapsulated bytes, restores the signed SET tag, and verifies the RSA signature
on those exact signed attributes. No plist is released by the verifier until
signature **and** signer trust/purpose checks pass. Duplicate certificates,
ambiguous signer selection and digest/algorithm substitution fail closed.

The purpose policy was reviewed at immutable Apple Security source revision
`db15acbe6a7f257a859ad9a3bb86097bfe0679d9`, function
`SecPolicyCreateiPhoneProvisioningProfileSigning`: a three-certificate Apple-rooted
chain, leaf CN `Apple iPhone OS Provisioning Profile Signing`, issuer/intermediate
CN `Apple iPhone Certification Authority`, and no networked revocation checks.
The implementation uses system BasicX509 trust at the supplied **current** time,
disables trust network fetches, rejects explicit user trust overrides, requires
that exact chain length/names, and pins the evaluated root's SHA-256 to reviewed
production Apple Root CA/G2/G3 certificates. Embedded arbitrary roots are never
installed as anchors; signingTime cannot backdate trust. These conservative public-
API constraints are not a claim of full parity with Apple's private policy across
OS versions. Development-certificate trust/purpose/revocation remains separate.

`apple-cms-policy-review.json` records immutable source/root paths, hashes and
scope limitations in preparation provenance. Review used public source and public
certificate inspection/fingerprints only; no real profile or account credentials
were used. Root assets are not bundled as arbitrary new device trust anchors.

Eight deferred CMS fixtures cover structural digest/attribute/algorithm/length
rejection, fake-certificate rejection, finite trust time and an ephemeral RSA
signature/tampering primitive. **None ran**; the primitive fixture will generate
an in-memory nonpersistent test key only when executed later. There is no positive
end-to-end production Apple-chain/CMS fixture yet; structural or primitive success
alone is never signing authorization. One new preparation regression is also
written/unrun. Current provenance is **57 first-party inputs plus four SDK additions**.

Static Swift grammar/Python syntax/diff checks only. No native compiler/build/test,
CMS/signature/trust evaluation, signing key generation, actual Apple request,
Keychain operation, Actions dispatch, commit or push occurred. This security-
sensitive implementation requires native API, positive/negative cryptographic,
malformed-input and compatibility validation before promotion. Remaining coding:
profile bridge/facade assembly, final certificate/IPA acceptance, renewal,
signing/install/refresh and primary-host integration; `notIntegrated` is unchanged.

## Profile bridge/facade assembly (coding continuation)

The isolated account backend now exposes `recordExplicitProfileCreationApproval`,
`revokeProfileCreationApproval`, `createAccountProvisioningProfile` and
`reconcileAccountProvisioningProfile`. This is **source assembly, not normal-app
integration or a production-readiness promotion**. The public factory deliberately
leaves the CMS verifier unselected. Approval/recovery fail with
`cmsVerificationUnavailable` before context/store/identity/provider/portal I/O;
an unminted creation grant also cannot enter setup. Tests can explicitly inject
an internal verifier; external callers cannot supply mock verifiers/CSR/CMS bytes.

`NativeAccountProfileTarget` contains an owned identity UUID, exact bundle/device
selection and registered App ID/device IDs. These IDs are selections, not trusted
remote authority. Certificate material/ID is derived internally from the current
durable owned-identity projection. The bound adapter freshly verifies the exact
remote device/App ID/certificate bindings. An optional existing profile UUID is
recovery-only and cannot mint a creation approval. Public results expose only an
operation UUID, authenticated profile UUID and expiry—not CMS/private key/session
material or signing readiness. CMS is not newly persisted or exported by the facade;
future signing execution must retain/recover its authenticated artifact internally.

One opaque, single-use grant binds owner, context, exact target, derived owned-
certificate request, generation and epoch, with at most 120 seconds of authority.
It is consumed before asynchronous setup. Creation re-derives the owned request
and rejects changes; a per-operation executor delegates only the remaining approved
lifetime. Anisette consent is separately required and never substitutes for quota-
affecting profile approval. Existing intents prevent new approval; read-only
recovery never creates, resets uncertainty, renews or silently cleans up resources.

Profile workers now participate in every existing ordinary shared busy check
alongside authentication, preflight, identity, certificate and registration work.
Revocation/sign-out/shutdown invalidate authority and cancel workers without
prematurely clearing their busy slot or namespace lifetime. Worker checks bind
current context/consent/generation/approval epoch around actor/provider hops;
authority is capped by session/consent/approval expiry. Argument-free fresh headers
and a live owned-identity callback feed the bound portal. Bound authorization is
invalidated on both success and error. Cancellation or uncertain HTTP completion
never erases the durable profile journal.

Twelve new native fixtures are written/unrun: four target validation/hash/redaction
fixtures, three default/unminted gate cases, and five injected fake-vault grant/
resource-rejection/shared-slot cases. The injected verifier always rejects CMS;
these are not positive Apple CMS, Keychain, lease-lifetime or real network proofs.
The fixture free-team ID was made ten characters to match profile constraints.
One preparation regression is also written/unrun. Provenance now has **59 first-
party inputs plus four SDK additions**, with dependency pins unchanged.

Static grammar/Python syntax/diff checks only; no native build/test, CMS/trust
execution, signing keys, Apple/provider requests, Keychain operations, Actions,
commit or push. Remaining coding includes final certificate/IPA acceptance,
artifact handoff to signing/install/refresh, renewal and primary-host assembly.
Actual CMS/legacy endpoint compatibility and all native/device behavior remain
unvalidated; normal app capability stays `notIntegrated`.

## Main-file acceptance and internal handoff candidate (coding continuation)

`NativeMachOInspection` now inspects actual supplied main-executable bytes, not
caller-declared entitlement metadata. The initial subset is thin ARM64 (generic
subtype) MH_EXECUTE with bounded header/load-command envelopes and embedded
code-signature superblob indexes. It rejects encryption with a nonzero cryptid
(**no decryption or DRM bypass**), unsupported architectures/formats, malformed
command/signature bounds, duplicate/overlapping signature slots, and DER-only or
dual XML/DER entitlement claims. XML claims are extracted as **untrusted requested
claims**; the original CodeDirectory/CMS signature is NOT authenticated here.
Unsigned executables can have no original entitlement claims.

`NativeMainAppAcceptance` checks exact Info.plist bundle/executable/package/device-
platform metadata, rejects root extension/watch layouts, and permits only the
existing narrow main-app entitlement subset. Foreign identity and singleton own-
app keychain claims can be rewritten to authenticated profile identity; shared/
wildcard keychain groups, push/app-group/unknown capabilities and malformed boolean
claims reject. Output entitlements are generated from profile constraints, never
an arbitrary copy of the original claims. Binary or UTF-8 Info plists are supported;
untrusted ENTITY declarations/nonstandard DTDs reject before OS plist parsing.
The inert standard Apple plist DOCTYPE is removed for policy parsing. Original
source bytes are retained unchanged. OS parser allocation/depth behavior and all
native malformed-input handling remain unvalidated; byte limits are not a proof
of a hard OS-parser memory/CPU ceiling.

The authenticated profile artifact now retains the **certificate hash and device
identifier actually validated by its CMS gate**. Main-file handoff requires those
exact bindings plus team/application/keychain/optional UUID agreement, profile
expiry and the exact CMS-envelope hash. Merely sharing a team/bundle is not enough
to substitute another owned certificate/device. The internal, redacted
`NativeAccountSigningCandidate` holds exact source bytes/hashes, identity reference,
profile/CMS and generated entitlement bytes with a maximum 30-second lifetime.
It exports no private key, performs no signing and is explicitly **not execution
authority**. Future execution must recheck current identity/context and all gates.

**This is not complete IPA acceptance.** There is no ZIP extraction/inventory gate,
resource-path/symlink/case-collision validation, complete segment/entrypoint/dylib
validation or nested executable/framework/extension acceptance yet. Main-file
inspection must never stand in for a verified complete archive scan. Development-
certificate chain/purpose/revocation and install-target authority also remain
separate missing gates. No API accepts this candidate to execute signing; it is
not wired into the public backend, and default CMS/UI gates remain unchanged.

Ten synthetic native fixtures and one preparation regression are written/unrun,
covering executable/encryption/signature envelopes, Info metadata, entitlement
rewrites/rejections, DTD rejection and candidate certificate/device/expiry binding.
Fixture CMS verification is explicitly fake, not a positive Apple trust proof.
Preparation provenance is now **62 first-party inputs plus four SDK additions**;
main dependency pins are unchanged. Static grammar (four changed Swift files),
Python syntax and diff checks only. No native build/test, Mach-O/IPA/signature/trust
execution, key generation, Keychain/Apple/provider requests, Actions, commit or
push. Complete archive/certificate acceptance and signing/install/refresh/runtime
integration remain unfinished; normal app stays `notIntegrated`.

## ZIP32 record inventory and single-main-app namespace (coding continuation)

`NativeIPAArchiveIndex` now reads actual ZIP bytes with no filesystem extraction.
It binds one terminal EOCD to the complete central directory and every referenced
local header/payload/optional signed or unsigned data descriptor. Names, flags,
method, timestamps, CRC metadata and sizes must agree. Sorted local record ranges
must cover the archive prefix exactly: overlap, hidden gaps, prepended stubs,
trailing unexplained records and malformed directory counts reject. The index
retains exact compressed byte ranges and a hash of the source archive.

This strict first subset accepts single-disk ZIP32, stored or raw-deflate methods,
ASCII paths and inert timestamp/UID-GID extras only. It rejects ZIP64, encryption,
unsupported flags/creator hosts/extras (including alternate Unicode filenames),
symlink/device/nonregular Unix types, and directory entries carrying compressed
content. File permissions/ownership are never materialized. Archive paths reject
absolute/traversal/control/backslash/colon/empty/trailing-dot-or-space components.
Exact and case-folded duplicate names, implicit parent case aliases and file/
directory conflicts reject regardless of central-directory ordering. ASCII-only
is deliberately conservative, not support for every valid international IPA.

Bounds: input <=128 MiB, <=10,000 records, path <=1024 bytes/32 components,
component <=255 bytes, aggregate names <=4 MiB, <=20,000 unique implicit namespace
nodes/8 MiB spelling bytes, per-entry expansion declaration <=128 MiB,
aggregate <=512 MiB, ratio <=250, extras <=4 KiB. These bound this parser's declared
work; native allocation/performance behavior is unvalidated, not a device-memory
or whole-pipeline resource guarantee.

`NativeIPAArchiveLayout` permits a single `Payload/<name>.app`, with exact nonempty
bounded Info.plist and optional explicit parent directory records. The initial
subset rejects outside-Payload metadata/multiple apps and named nested extension,
framework, watch, dylib or XPC layouts rather than silently dropping them. These
rejections are deliberate incomplete compatibility, not permanent product scope.

**Neither type is signing authority or complete IPA acceptance.** Compressed bytes
have not been inflated, CRC metadata is not an actual checksum verdict, Info.plist
contents are not validated by this layout stage, and names cannot prove absence
of disguised executables. A mandatory all-entry bounded decoder/checksum/content
scanner and eventual nested-code support remain unfinished. There is no extraction,
install or signing endpoint for these types, and no public/UI/CMS promotion.

Nine archive fixtures and one preparation regression are written/unrun. One
fixture intentionally demonstrates that index acceptance does NOT authenticate a
zero CRC against nonempty content. Other cases cover descriptor forms, record/
name mismatches, aliases/conflicts, unsafe paths, encryption/symlink/ZIP64/extras,
limits, layouts and nested-code rejection. Preparation now records **65 first-party
inputs plus four SDK additions**, main pins unchanged. Three Swift files passed
static grammar; Python syntax/diff checks only. No native build/test, actual ZIP
inspection/decompression, key/CMS/signature/Keychain/provider/Apple operations,
Actions, commit or push. Coding continues before the requested CI/test phase.

## Bounded entry decoding and all-entry content inspection (coding continuation)

`NativeIPAEntryDecoder` implements stored entries and Apple Compression's raw-
DEFLATE path without calling a permissive archive extractor. Output is checked
against the declared length **before append**, with fixed 64-KiB scratch space,
progress checks, cancellation, required stream completion/library-reported full
input consumption and independent CRC-32/IEEE validation. Truncated, oversized,
no-progress, checksum-mismatched or reported unconsumed-input streams reject;
there is no decoder fallback or partial-success result. Deflate input is borrowed
inside a bounded source range, not copied into another archive-sized buffer.
Stored entries respect Data slice start indices. CRC loops/index parsing also
check cancellation periodically. The actual Apple Compression ABI/raw-deflate/
trailing-input behavior remains UNVALIDATED until native fixtures run; these
checks are written requirements, not an executed compatibility/security proof.

`NativeIPAContentVerifier` now constructs its own index/layout, CRC-validates and
hashes **every entry**, validates Info.plist's exact bundle/platform/executable
selection, requires the selected main executable, and applies main Mach-O
inspection. Additional Mach-O/fat/static-library bytes under otherwise harmless
resource filenames reject. It retains exact Info/main bytes, all entry hashes,
expanded count and archive hash in an internal redacted content artifact. It does
not extract files, overwrite provisioning, sign, install, trust the publisher or
turn the earlier main-file candidate into execution authority. A later execution
boundary must consume/rebind this complete artifact, not bypass it via main-file
metadata alone. Full Mach-O segment/entrypoint/dependency semantics and unsupported
nested/framework layouts remain separate missing support.

`NativeIPAContentInspection.inspect(archive:bundleIdentifier:)` exposes a read-only
public receipt (archive hash, bundle ID, entry count, expanded bytes) without
requiring an account, backend lease or key. Work runs detached from the caller's
actor and is awaited through actual retirement even after cancellation. A process-
local slot prevents concurrent public memory-intensive inspections; internal
pipeline callers must serialize likewise. Fixed public errors replace raw parser
errors. This API does NOT export contents, sign, acquire credentials or perform
network/filesystem operations. It is currently part of the isolated native module,
not linked into the normal app UI. Resource limits are not a measured iOS memory/
performance guarantee; OS parser/decoder allocations remain unvalidated.

Eleven native fixtures and one preparation regression are written/unrun: independent
CRC vectors, stored/raw-deflate/empty stream, truncation/trailing/overflow, complete
entry hashes, source Data slices, corrupt resources, disguised code, exact main
selection, cancellation and public receipt/error behavior. Fake Mach-O headers
are not runnable-app or original-signature proofs. Preparation provenance now has
**69 first-party inputs plus four SDK additions**, main dependency pins unchanged.
Static grammar/Python syntax/diff checks only; no native build/test, actual archive
inspection/inflation/CRC operation, CMS/trust/signing, key generation, Apple/provider
request, Keychain operation, Actions dispatch, commit or push occurred.

### End-to-end completion is still pending

This completes source implementation of the supported archive-content inspection
stage, not the whole user request. Inspection of existing `SigningService`,
`ZsignEngine`, `AppInstaller`, `BackgroundAutomation` and `SigningMethodsView` did
not change their readiness. The native backend still needs production development-
certificate trust/purpose/revocation, a protected live-identity/verified-artifact
handoff to a concrete signer, output verification/packaging, paired installation
with device-side evidence, quota-safe renewal/refresh, normal-app dependency/link
assembly and corresponding UI/task-state wiring. Existing imported-certificate
signing/install/automation paths are not proof of a native account pipeline. The
unvalidated CMS implementation is not selected by default, and the ordinary app
remains `notIntegrated`. No signing/install-ready flag or credential-entry UI was
added to disguise those gaps. Native/CI testing remains deferred as requested.

## Development-certificate gate and protected pre-sign assembly

The sequential completion ledger is `docs/NATIVE_SIGNING_COMPLETION.md`; it marks
source work separately from native validation and explicitly lists unfinished
signing/install/refresh/UI integration. This continuation does not finish all of
those stages or promote readiness.

`NativeDevelopmentCertificatePurpose` strictly parses the supported v3 leaf's
single exact team OU, development marker `.6.1.2`, exclusive code-signing EKU,
digitalSignature-only key usage and non-CA basic constraints. Duplicate extensions,
ambiguous team OUs, distribution/TestFlight/CA/other-purpose substitutions and
unsupported structures reject. WWDR marker `.6.2.1` is required on the evaluated
intermediate. Purpose parsing is NOT certificate trust; synthetic parse fixtures
intentionally have invalid public keys/signatures.

`NativeDevelopmentCertificateVerifier` uses public Security BasicX509 current-time
trust, exact evaluated leaf/three-link chain, pinned production Apple roots, WWDR
purpose and rejection of user trust overrides. A second policy evaluation REQUIRES
positive cached OCSP/CRL via `kSecRevocationRequirePositiveResponse` and disables
network fetching in both trust and revocation policies. Missing/unknown/unreachable
status never becomes valid. This concrete offline path will block when caches or
issuers are unavailable; explicit online-disclosure consent/issuer supply remains
unfinished and is not inferred from anisette or certificate-creation approval.
Evidence is audit-only, not a cached signing permit or an OCSP-nextUpdate guarantee.
Fresh evaluation is required at each later protected execution boundary.

`NativeProtectedSigningHandoffFactory` defaults to the closed CMS gate before any
archive, callback, identity or trust access. With an explicitly selected verifier,
it binds owner/context/exact target and current owned certificate/device, scans
all archive contents off the caller actor with retained cancellation retirement,
reprojects ownership, reauthenticates exact CMS/UUID, evaluates development trust/
positive cached status, reprojects once more and builds narrow entitlements. The
internal redacted result preserves FULL archive/entry hashes, main/profile bytes,
certificate evaluation, capped deadline and actual namespace lifetime. It exports
no key, PKCS12, engine callback or install path. It is read-only pre-execution
assembly, NOT an explicit signing approval, key delegation or reusable permit.
The owning bridge must still supply real current-context/resource authority.

Immutable Apple policy/header source plus four downstream signing/key API files
were reviewed; hashes and scope are in `development-certificate-review.json`.
SideSign's convenience signer has a first-profile fallback and broader group
rewriting; KeyStore exposes/exports key bytes, and CodeSignKit's CMS signer embeds
a hardcoded issuer. These are concrete reasons NOT to enable native readiness by
calling that convenience API unchanged. No SDK signing or secret export occurred.

Ten new native purpose/trust-negative/handoff-gate fixtures and one preparation
regression are written/unrun. There is no positive real Apple chain/revocation
fixture or native API proof yet. Provenance is **74 first-party inputs plus four
SDK additions**, main dependency pins unchanged. Static checks only; no native
build/test, actual certificate/CMS/trust/revocation evaluation, key generation,
Keychain/provider/Apple request, Actions, commit or push. The normal app remains
`notIntegrated`; the full end-to-end user request is still unfinished.

## Explicit online certificate status and reviewed issuer supply

The native module now has separate single-use certificate-status disclosure
consent (<=120 seconds), exact owner/context/identity/certificate/generation/epoch
binding, wall-clock rollback rejection plus a monotonic expiry ceiling,
consume-before-online setup, revocation and worker-retirement retention.
It is not anisette consent, quota approval or signing/install permission. The
verifier still authenticates current Apple development purpose/chain OFFLINE first;
only then can an exact grant enable system status networking. Both modes require
positive OCSP/CRL; missing/unknown status never means valid. Revoked/expired context
or consent rejects even after an uncooperative OS call completes. OS trust calls
cannot be forcibly interrupted; the busy slot/lease remain held until retirement.

The public account backend now exposes `recordExplicitCertificateStatusConsent`,
`revokeCertificateStatusConsent` and `evaluateSigningCertificateStatus`. No token
means offline cached-positive-only. Results contain certificate hash/check time,
not certificate/key/session bytes or a reusable signing permit. Fresh durable owned
certificate projection was factored from the existing profile projection without
inventing bundle/device placeholders. Ordinary bridge busy checks now include
status workers; sign-out/shutdown/revocation invalidate them before actor hops.
The protected read-only handoff can accept the same scoped authorization, but no
actual signing/private-key delegation or normal-app UI has been enabled.

Issuer supply now includes one reviewed PUBLIC WWDR G3 certificate, SHA-256
`dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f`.
Its immutable CodeSignKit source and DER fingerprint are recorded in the review
manifest. Public OpenSSL subject/issuer/date/fingerprint inspection was performed;
this is not signature/status verification or a native test. It is only a bounded
issuer candidate, NEVER an added trust anchor. Other issuer generations fail closed.
Online status uses OS certificate infrastructure after explicit disclosure consent;
no custom URL/TLS bypass or arbitrary application downloader was introduced.

Additional immutable engine source review found that MachOSigner emits both XML
and DER claims and that pinned DEREncoder emits true as 0x01 rather than canonical
DER 0xff. That requires a reviewed correction and independent output verification;
calling the convenience signer and advertising completion would be unsafe. Review
hashes/findings are in development-certificate-review.json. No engine was invoked.

Eight new consent/issuer/verifier-order fixtures plus two bridge ownership/retained-
slot fixtures and one preparation regression are written/unrun. Preparation now
records **77 first-party inputs plus four SDK additions**, main pins unchanged.
Static Swift grammar (nine files), Python syntax/diff only; no native build/tests,
OCSP/CRL/Apple/provider request, trust evaluation, signing/key generation, Keychain
operation, Actions, commit or push. This finishes source for ledger step 5 within
the supported G3 subset; concrete signing/output/packaging/install/refresh/normal-
app/UI stages still remain unfinished. Default CMS/readiness gates are unchanged.

## Signed-output consistency and transport implementation

Added an independent narrow CodeDirectory verifier (v0x20400, SHA256, ARM64
4K/16K pages): exact identifier/team/header/string/hash layout, code limit, every
code-page digest including partial final pages, special slots 1/2/3/5/7, zero
absent slots, exact text-file range and MAIN_BINARY-only flags. No unsigned/JIT
execution flags are accepted. Its receipt proves byte/hash consistency ONLY;
full Mach-O semantics/mutation/resource policy and artifact sealing remain pending.

Added detached code-CMS parsing as an explicit SEPARATE role. The provisioning
profile entry point still rejects detached content. Code signatures must omit
attached content and bind the externally supplied directory through signed SHA256
attributes. The consistency verifier requires a unique issuer/serial match to the
exact expected certificate and verifies RSA PKCS1v1.5/SHA256 via Security. It does
not grant certificate trust, revocation, ownership, execution or install authority.
No self-signed/foreign CMS can become a trusted artifact merely by parsing it.

Added deterministic bounded stored ZIP32 encoding, fixed timestamps, regular-file/
directory modes, no extraction or URL inputs, and independent index/namespace plus
all-record decode/CRC readback before transport bytes return. This is a transport
primitive, NOT an IPA signing receipt or an installer input. A private workspace,
full output verification and opaque artifact sealer still need integration.

The preparation path now has a hash-locked, three-site canonical DER BOOLEAN
correction for pinned CodeSignKit. It preserves upstream originals and records
before/after hashes in provenance; changed/unreviewed sources fail closed. This
correction is source/preparation code only, not a native engine validation. Upstream
ALLOW_UNSIGNED exec-segment flags are rejected by the narrow directory policy;
engine selection/strict flags still need resolution before enabling signing.

Six output/ZIP fixtures, two CMS-role fixtures and two preparation regressions
were added, all unrun. There are now **81 first-party inputs, four SDK additions
and one hash-locked upstream DER correction**. Static grammar/Python syntax/source
registration/whitespace checks only; no native compile/tests, signing/trust/keys,
Keychain, Apple/provider/OS status requests, Actions, commit or push. Protected key
execution, verified artifact release, paired installation, renewal and actual app/
UI wiring remain unfinished. Capability/default CMS gates have not been opened.

## Composed output claims and archive/resource policy (source only)

`NativeOutputEntitlements` now independently encodes the narrow four generated
claims as canonical DER (true=0xff), compares DER bytes and requires XML to exactly
match the approved candidate's generated XML. Exact application/team/group/debug
values, strict CFBoolean type, frame magic/length, unknown claims and extra bytes
are checked. This is not a generic untrusted entitlement encoder or a claim of
native kernel acceptance; iOS compatibility/native vectors are still unvalidated.

`NativeStrictCodeResources` defines a deliberately strict deterministic XML seal:
all real resources (including Info.plist and exact embedded profile), mandatory
SHA256 plus legacy SHA1, no omit/optional/nested rules. It writes its own escaped,
ordered XML; verification uses exact independent bytes rather than interpreting
an untrusted engine plist with duplicate keys, DTDs or altered rule semantics.
The SDK default resource policy is NOT automatically compatible; the future
strict adapter must use this policy rather than fall back to permissive rules.

`NativeResourceSealVerifier` binds original archive bytes to the full content
receipt; independently indexes output/layout and CRC-decodes EVERY output entry.
Every original file/directory must remain unchanged except main code, the exact
expected profile, and root signer-owned signature metadata. Only new profile/
CodeResources/signature-directory paths are allowed; arbitrary additions, removal
of resources, changed Info.plist, changed groups, or resealed resource injection
fail. The receipt binds source/output/main/seal/profile hashes but proves neither
Mach-O instruction/load-command mutation safety nor certificate/profile authority.
The expected profile bytes must come from the fresh authenticated candidate.

`NativeMainSignatureConsistency` connects the output primitives: exactly one each
of directory/requirements/XML/DER/CMS wrapper, unique nonoverlapping contiguous
ranges, zero allocation padding, no alternate directories/unknown slots, approved
claims, every directory hash, exact expected CMS signer and RSA signature. The
requirements bytes are hash-bound, but their semantic policy remains unfinished.
This receipt deliberately does NOT authorize artifact release or installation.

Ten new native policy fixtures and one registration regression are written/unrun.
Preparation now maps **86 first-party inputs**, plus the four SDK additions and
one hash-locked upstream DER correction. Static grammar of six changed/new Swift
files and Python syntax/source-registration/whitespace checks only. No compiler,
native tests, keys, signing, Keychain, trust/status/provider/Apple calls or Actions.
Full Mach-O semantics/mutation/requirements policy, protected execution, private
workspace and verified artifact release, installation, renewal and app/UI wiring
remain incomplete. CMS/default readiness gates remain closed.

## Narrow image-bound Mach-O mutation verification

Added a strict first mutation dialect: thin ARM64 subtype 0 MH_EXECUTE, bounded
commands, disjoint bounded file/VM segments, checked section/file mappings and
alignments, no relocations, no writable+executable mappings, no executable-stack/
flat-namespace header flags, and a four-byte-aligned LC_MAIN entry within an
instruction-marked file-backed section. Existing terminal signature allocation in
read-only __LINKEDIT is mandatory; absent signature commands/insertion, moved
signature offsets and relocation of code/data are unsupported. Encryption cannot
be enabled; alternate thread entry commands and selected unsupported command forms
reject. Duplicate segments/signatures/entry/encryption commands reject.

`NativeMachOMutationVerifier` compares EVERY byte before the signature allocation
except the exact __LINKEDIT VM/file-size and signature offset/size fields. Output
must independently pass the same layout checks; text bounds and signature offset
cannot change. Span comparison uses pinned raw buffers, not full-prefix temporary
copies. The signature content/allocation may change, but no code/instruction/data/
other-load-command rewrite is allowed. This intentionally excludes the SDK's
command-insertion and code-moving dialects rather than silently accepting them.

`verifyMutationAndSignature` now extracts actual signature/prefix/text ranges from
validated images before composing claims, directory and detached signature checks.
It does not let a caller substitute arbitrary prefix/signature slices. However,
unknown preserved load commands are NOT semantically authorized by this subset:
full dyld/dependency/linkedit-reference/designated-requirement policy and native
compatibility vectors are still pending. Evidence is NOT execution/install rights.

Five synthetic layout/mutation fixtures and one preparation regression are written,
unrun. Preparation now maps **88 first-party inputs**, plus four SDK additions and
one hash-locked DER correction. Static Swift grammar (three files), Python syntax,
source-registration/whitespace/diff only. No native compile/tests, keys, signing,
trust/Keychain/Apple/provider/status operations, Actions, commit or push. Private
signer execution/workspace/sealed artifact/install/renewal/app wiring remain gated.

## Exact native designated requirement policy (source implementation)

Added `NativeDesignatedRequirement`, reviewed against immutable Apple Security
requirement.h/reqmaker.cpp/reqinterp.cpp/CSCommon.h (hashes and constants in
`designated-requirement-review.json`). The ONLY accepted requirement set contains
one designated expression: exact bundle identifier AND exact leaf certificate's
legacy SHA1 requirement digest (leaf position zero). Encoding includes canonical
big-endian fields and zero four-byte alignment padding. Exact byte comparison
rejects alternate slots/types/versions/opcodes, OR/skip clauses, modified identity,
unknown subexpressions, extra requirements and trailing data; it is not a generic
requirement interpreter with permissive fallback.

The combined main signature consistency path now enforces this policy before
checking claims, CodeDirectory hashes and CMS. The strict signer adapter must
emit this requirement rather than rely on the SDK's default requirement builder.
Apple's legacy requirement digest is SHA1; it is NOT the certificate trust or CMS
signature primitive. Exact expected certificate DER and RSA/SHA256 CMS checks,
profile authentication and fresh Apple development/status/ownership checks remain
independently mandatory. A requirement match alone proves none of those things.

Renewed certificates regenerate the leaf-pinned requirement. Device update/
keychain/refresh continuity across renewal is unvalidated and must not be assumed.
Native platform evaluation/compatibility is also unrun. The dependency/dyld/
linkedit-reference policy, live protected signer, workspace and opaque artifact
release/install/renewal/app integration are still incomplete; no readiness gate
was promoted.

Five policy fixtures plus one preparation regression are written/unrun. Preparation
maps **91 first-party inputs**, plus four SDK additions and one upstream correction.
Static Swift grammar (three files), Python syntax/registration/whitespace/diff only;
no native compiler/tests, key/signing/Keychain/trust/status/Apple/provider calls,
Actions, commit or push. Source review is not platform or end-to-end validation.

## System-only loader envelope (not full dyld bytecode validation)

`NativeMachOLoaderPolicy` now fails unknown/preserved load commands closed instead
of relying solely on unchanged bytes. It requires an exact /usr/lib/dyld command
and iPhoneOS version metadata (never simulator/MacCatalyst), canonical system-only
framework/library paths, unique dependencies/singletons, bounded symbol/string/
indirect/dyld/linkedit-data references entirely before the signature in __LINKEDIT,
limited non-relocation dynamic-symbol tables, and basic nlist string/section/library
ordinal bounds. Dynamic-lookup/executable ordinals, RPATH/environment/reexport/
upward/lazy/ID/unknown forms and noncanonical command strings are rejected.
System path acceptance is not proof of actual dependency availability on a device.

The accepted dependency dialect includes /System/Library/Frameworks/X.framework/X,
/usr/lib/lib*.dylib and /usr/lib/swift/lib*.dylib only. @rpath/@loader_path and embedded
frameworks are deliberately unsupported, including otherwise legitimate Swift
apps that use them. No unsafe host-filesystem or arbitrary URL resolution is used.
Both original and output images pass this policy before mutation/signature checks.

Immutable cctools loader.h/nlist.h source revision/hashes are recorded in the
certificate review manifest. Bind/rebase/export/chained-fixup payloads are RANGE
checked, not interpreted or semantically approved; complete dyld payload validation
is still a blocking boundary before execution/artifact release. This gate also
has no certificate/profile/context/install authority.

Five synthetic native fixtures and one prep regression are written/unrun. The
source map is **93 first-party inputs** plus four SDK additions and one correction.
Static Swift grammar (four files), Python syntax/registration/whitespace/diff only;
no native compiler/tests, key/signing/trust/Keychain/Apple/provider/status calls,
Actions, commit or push. Protected signing, workspace/sealed artifacts, install,
renewal and app/UI wiring are still incomplete; default readiness gates stay shut.

## Legacy dyld pointer bytecode validation (source-only restricted dialect)

Added bounded canonical ULEB decoding and stateful legacy rebase/regular/lazy bind
validation. Actual on-disk pointer locations must be aligned, writable/non-executable,
file-backed and pre-signature. Rebase values must refer to non-null in-image mapped
file data; regular bind slots must be zero; lazy slots may hold an aligned mapped
executable helper address. Positive existing dependency ordinals, bounded nonempty
ASCII symbols, pointer-only types, explicit stream termination and limited zero
padding are enforced. Repeat/skip arithmetic cannot wrap; duplicate writes reject,
except the explicitly supported rebase-then-lazy-bind pair on the same helper slot.
A 262144-target budget and cancellation checks bound work, including repeated opcodes.
This validates pointer actions, not executable instructions or actual symbol presence.

The loader now passes actual original/output LC_DYLD_INFO_ONLY stream slices and
validated segment/dependency context to this decoder. Unsupported weak-binding and
nonempty legacy export streams reject. Export-trie and chained-fixup commands now
reject outright even if their ranges fit; they are no longer accepted on bounds
alone. Special ordinals, threaded/authenticated/non-pointer forms, weak symbol
flags and explicit addends are unsupported, not silently treated as safe. Zero-fill
rebase referents and other legacy dialects may also reject. Full export/fixup and
other payload semantics, native ABI/runtime vectors remain pending.

Eight bytecode fixtures, one loader integration fixture and one preparation
regression are written/unrun. There are **95 first-party inputs**, four SDK additions
and one correction. Static Swift grammar (four files), Python syntax/registration/
whitespace/diff only; no native compilation/tests, dylib loading, pointer writes,
keys/signing/trust/Keychain/Apple/provider/status/Actions. Protected execution,
workspace/sealed artifact release, paired installation, refresh and app/UI wiring
remain unfinished and gated. No full loader or end-to-end completion is claimed.

## Export trie validation (source-only regular export dialect)

Added a bounded export-trie decoder for regular and weak regular exports. It
validates canonical ULEBs, terminal sizes/flags/addresses, ASCII edge names, unique
first-character branches, symbol names, acyclic/unshared node offsets, depth/node/
name-byte budgets and complete disjoint node coverage. Interior gaps/unreachable
payload and excess/nonzero tail bytes reject; at most seven zero padding bytes
are permitted. Export addresses must map to pre-signature file-backed image data.
This validates metadata, not symbol resolution or executable function semantics.
Reexports, resolver stubs, TLS/absolute exports and other flag dialects reject.

Both LC_DYLD_INFO_ONLY's legacy export stream and LC_DYLD_EXPORTS_TRIE now call the
same decoder. Simultaneous nonempty legacy and dedicated exports reject, rather
than allowing ambiguous alternate authorities. Chained-fixup commands remain
unsupported and fail closed. An empty canonical root is valid; malformed bounded
export payloads are no longer accepted merely because they fit __LINKEDIT.

Six new export fixtures, an updated loader integration fixture and one new prep
regression are written/unrun. Preparation maps **97 first-party inputs**, plus four
SDK additions and one correction. Static Swift grammar (four files), Python syntax,
registration/whitespace/diff only; no native compiler/tests, symbol/dylib loading,
keys/signing/trust/Keychain/Apple/provider/status/Actions. Chained-fixup/remaining
payload semantics, protected execution, workspace/sealed artifacts, installation,
renewal and normal-app/UI wiring remain incomplete. No readiness gate promotion.

## Restricted chained-fixup decoder (source implementation)

Added the uncompressed DYLD_CHAINED_PTR_64_OFFSET (format 6) / DYLD_CHAINED_IMPORT
(format 1) dialect. Header/starts/import/string structures must be bounded,
disjoint and fully accounted for except small zero alignment gaps. Segment VM
relative offsets, 4K/16K pages, page starts and eight-byte pointer slots are checked.
Chains stay in writable non-executable pre-signature file data, terminate inside
their page and cannot duplicate targets or exceed the 262144-pointer budget.
Rebase targets must map to in-image file data; bind indices must select a validated
import. Reserved/high-tag bits, pointer addends and misaligned next strides reject.

Imports require positive system-library ordinals 1...240 (0xf1...0xff are SPECIAL,
not positive indices), no weak flag, and canonical NUL-terminated ASCII symbol-pool
starts. Suffix aliases/unreferenced names, compressed symbols, addend import forms,
authenticated/other pointer formats and multi-start pages are unsupported. Counts,
coverage/pointer scans and cancellation checks are bounded. This does not perform
runtime pointer writes, symbol lookup or installed-library availability checks.

The loader now invokes the decoder for LC_DYLD_CHAINED_FIXUPS. Nonempty classic
rebase/bind/lazy streams cannot coexist with chains. Immutable Apple dyld
fixup-chains.h revision/hash and format decisions are recorded in the review
manifest; the cctools tree lacked this header, so its separately pinned dyld source
was reviewed instead. Source inspection is not native ABI/platform validation.

Seven new synthetic fixtures (including loader integration), an updated malformed-
payload fixture and one new preparation regression are written/unrun. Preparation
now maps **99 first-party inputs**, plus four SDK additions and one correction.
Static Swift grammar (four files), Python syntax/registration/whitespace/diff only;
no native compiler/tests, actual pointer writes/dylib loading, keys/signing/trust/
Keychain/account/provider/status operations or Actions. Remaining payload/platform
policy, protected execution/workspace/sealed artifacts, paired installation,
refresh and actual app/UI integration are still incomplete and gated.

## Whole packaged-output read-only audit (source implementation)

Added function-start delta validation against instruction-marked file ranges and
bounded sorted data-in-code/jump-table records with kind/alignment checks. Both
linkedit commands now invoke these decoders, not just reference-range checks. This
is metadata validation, not instruction disassembly or complete platform behavior.

`NativeSignedArchiveAuditor` now connects the existing checks into one READ-ONLY
whole packaged-output path: require explicit concrete CMS support; bind the exact
owner/context/target/input handoff; refresh original content/ownership/profile/
Apple certificate status; then detach output CRC/resource/mutation/loader/claims/
requirements/directory/CMS checks. It verifies shared main/info/seal/profile/leaf
hashes across those proofs. After the worker retires it repeats fresh input/profile/
identity/certificate checks (offline-positive, no reused network grant) before
returning redacted metadata. Cancellation does not abandon the detached worker or
release the retained backend lifetime early. The original handoff deadline remains
binding; output processing cannot extend it.

This does NOT return archive bytes/URLs, private keys, a cached signing permit or
an installation artifact. It does not sign, extract, package files on disk or
install. The public account facade/UI has NOT been wired to claim signing readiness.
Default CMS selection remains unavailable. Full positive trusted/native audit
vectors, cross-payload/platform policy and device behavior are unvalidated; strict
subset rejections remain. Protected key execution, private workspace/artifact
release, paired install, renewal and app integration are still unfinished.

Four metadata fixtures and one preparation registration regression are written/
unrun; whole-audit trusted positive fixtures are not yet available. Preparation
maps **102 first-party inputs**, four SDK additions and one correction. Static Swift
grammar (five files), Python syntax/registration/whitespace/diff only; no native
compiler/tests, audit execution, key/signing/trust/Keychain/account/provider/status
operations, Actions, commit or push. No end-to-end or installation claim.
