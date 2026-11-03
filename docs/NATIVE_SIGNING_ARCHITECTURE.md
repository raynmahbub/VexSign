# Decision: one primary VexSign app

Date: 2026-11-02. Status: architecture accepted for implementation; native account
adapter, primary-host runtime port and end-to-end device acceptance are pending.

## Product contract

- The installed app is **VexSign**, with VexSign as the primary UI and host.
- Do not require installation/opening of VexSign itself as a guest or a separate
  SideStore/LiveContainer app to complete the integrated product workflow.
- Keep the existing `com.vexsign.app` identity/data where feasible. A necessary
  migration requires explicit backup/restore and documented compatibility, not a
  silent change to stock LiveContainer's bundle identifier.
- Five primary destinations: Library, Home, App Store, Activity, Settings.
  Reuse existing app/source/file/task views rather than copying competing UIs.
- Account provisioning and imported-certificate signing are different identity
  sources. They share the signer, workspace, task history and installation UI.
- Installing the app using a free account says nothing about in-app portal login,
  imported certificate membership, JIT permission or unattended renewal.
- Support a validated free-account baseline and imported paid-certificate path.
  Additional entitlements/hosting/background modes remain capability-dependent;
  no promise that every restricted feature works with every profile/device/OS.

## Target and module ownership

| Owner | Responsibility | Current position |
| --- | --- | --- |
| VexSign application target | Sole primary app lifecycle, five-tab UI, account/team chooser, Library, settings | Existing target; account UI not added yet |
| Native account service | SideSign adapter for Apple authentication/2FA, team enumeration, device/App ID/profile operations | Adapter not integrated; lifecycle foundation added |
| Secure identity store | Device-only Keychain session/private-key records, deletion and recovery | Byte adapter, isolated codec and durable resume repository written; Coordinator owns durable persistence; Isolated SDK/provider/Keychain assembly written; primary-app promotion/UI/native validation pending |
| Existing certificate/signing services | Imported identities, profiles, Zsign execution and output retention | Existing route; import crash/regressions need validation |
| Signing coordinator | Capture identity/team/options, provision, invoke signer, stage installation, reject stale results | Existing certificate flow; unified account orchestration pending |
| Installation service | Pairing/device install or existing authorized install method; explicit device result | Existing services; new native-account slice not connected |
| Primary host runtime | Upstream-derived bootstrap/hooks behind VexSign's own app lifecycle | Not ported into the VexSign target |
| Host support targets | Only required, capability-reviewed extensions/frameworks with VexSign-owned configuration | Existing experimental host targets are not final product targets |
| UnifiedTaskCenter | Shared phases, cancellation/retry and receipts without secrets | Existing; native account adapter integration pending |

A runtime port must replace hard-coded upstream bundle/path/URL assumptions with
owned configuration and audit all app-group, Keychain, widget, intent and extension
identities. Merely changing CFBundleDisplayName is not this port. Preserve the
bootstrap order before SwiftUI initialization; two competing app entry points are
not a workable integration. Guest process transitions may be necessary, but must
be managed by the one VexSign host.

Runtime hooks are not an OS security boundary against hostile native guest code.
Before combining account storage with guest execution, document the threat model
and supported isolation. Do not promise Keychain secrecy from code running with
the host's own authority; require trusted guests or a validated stronger boundary.

## Backend decision for the first account-signing slice

**Selected candidate: SideSign as vendored by the exact supplied Odysseus repo.**
Use its developer-portal/authentication API behind a VexSign-owned adapter; retain
the existing Zsign and installation pipeline initially. Do not embed an entire
second SideStore UI just to get an account login. SideStore-derived pairing and
renewal capabilities should become services behind the same product UI where
technically/licensingly supported. No claim of complete SideStore feature parity.

Evidence reviewed:

- Odysseus commit `2664dadedf9aca36fda0925a8aada92e2c79323f`,
  `SideSign/Package.swift` and `Feather/Backend/AppleID/ODAppleIDManager.swift`.
- The manager calls `DeveloperPortal.authenticate`, fetches teams, creates a
  device-local development identity, registers devices/App IDs and downloads
  provisioning profiles. Its header explicitly requests on-device testing.
- The example chooses the first free team preferentially and prepares a certificate
  during sign-in. VexSign will **not** copy those product decisions: require an
  explicit team choice, then explicit signing/provisioning intent. Never revoke an
  unrelated development certificate to free a slot automatically.
- SideSign needs Swift tools 6 and native dependencies. The reviewed package has
  several moving branch dependencies. `native-signing-dependency-review.json`
  records the exact direct dependency revisions resolved from GitHub for review.
  It is **not a complete transitive package lock or completed security audit**.
- Resolve/audit/pin the complete closure before linking. First build a native
  dependency/link smoke target with the existing Zsign/OpenSSL stack to expose
  ABI, deployment, symbol and crypto-library conflicts before adding account UI.

This is an implementation choice, not a statement that SideSign is already linked
or that the native Apple login flow works. No upstream account-manager code,
password-storage option or inert `canImport` provider was copied in this step.

## Authentication lifecycle foundation added now

`AppleAccountAuthenticationState` is a value-type state machine, not a login
implementation. It holds only opaque Keychain references and non-secret team/
expiry metadata; it is deliberately not Codable and has no singleton.

```
signedOut -> authenticating(operation ID)
          -> awaitingTwoFactor(same ID), when required
          -> awaitingTeamSelection(session reference + authorized teams)
          -> signedIn(new signing context ID)
          -> expired / signedOut
```

- A retry generates a new operation ID and rejects previous success, failure and
  challenge callbacks. Sign-out rejects pending callbacks too.
- Even one team requires explicit selection. Free/paid membership comes from the
  authenticated portal response, never from the bootstrap installer or a toggle.
- Team changes mint a new context ID. Provisioning/signing completions must match
  that context immediately before committing an artifact or queueing installation.
- Both local expiry checks and explicit server-invalidated-session handling block
  stale work. Do not treat an unknown expiry as proof of indefinite validity.
- Sign-out returns the owned credential reference for deletion; it does not itself
  implement Keychain deletion or remotely revoke certificates.
- `AppleAccountSessionCoordinator` now exclusively owns transient state and the
  durable persistence value on one worker actor. The standalone repository facade
  delegates to the same implementation, but must not coexist as another writer.
- Commit journals a fresh UUID, inserts session bytes and persists selection before
  accepting metadata, with no intervening actor suspension. A failed commit may
  leave a reservation; the coordinator invalidates that operation and requires
  durable cleanup before another login, rather than assuming no write occurred.
- Team hints persist before publishing signed-in state or a changed signing
  context. Failure preserves the prior state/context. Sign-out invalidates state
  before journaled cleanup; failed cleanup stays visible/retryable across restart.
- A failed initial sign-out-intent write cannot promise durable removal. Recovered
  candidates are never automatically signed in or treated as team authorization.
  Server revalidation and actual SDK integration remain pending. Cancellation
  alone cannot undo portal-side changes.

## Credential and provisioning requirements

1. No Apple password/session/2FA code in preferences, Core Data, logs, URLs, receipts,
   crash annotations, IPA files, backups or cloud signing endpoints.
2. Initial foreground slice: device-only Keychain records with narrowly scoped
   access. Do not persist an Apple password by default. Reauthentication should be
   explicit. Background-access policy requires a separate reviewed design.
3. Explain the anisette provider and obtain consent before authentication. Anisette
   data availability is not authentication. Do not send passwords or session tokens
   to an anisette provider; audit transport, logging and account-repair behavior.
4. Keep sign-out/local deletion separate from portal certificate revocation. Any
   revocation requires explicit review, identifies the affected certificate, and
   warns about other apps depending on it.
5. Before signing, verify private-key ownership, identity/profile dates, selected
   team, bundle identifiers/extensions, device authorization and actual granted
   entitlements. A successful Apple login is not a valid provisioning receipt.
6. Use isolated temporary workspaces and remove exported private material on all
   success/failure/cancellation paths. Prefer in-memory or narrowly scoped native
   identity access where the signer supports it.
7. Report signing, install-request acceptance, verified device installation and
   successful renewal as separate outcomes. Do not call a sent request installed.

## First vertical slice and acceptance evidence

| Step | Required result | Status |
| --- | --- | --- |
| Bootstrap | One identified desktop tool installs the primary VexSign app with a free account | Not verified |
| Dependency smoke build | SideSign + existing signing dependencies archive/link without unsafe crypto duplication | Isolated pinned graph and link target implemented; native build not run |
| Sign in | Authentication + optional 2FA; cancellation and errors recover safely | Isolated SDK adapter/broker written; app bridge/UI/native validation pending |
| Choose team | Explicit authorized free/paid team, no implicit first-team selection | State machine implemented; native UI/provider pending |
| Prepare identity | Device-local key/certificate, no silent revocation | Pending |
| Provision one IPA | Device registration, App ID/extension mapping, matching profile and expiry | Pending |
| Sign | Existing signer consumes the matching identity/profile in a private workspace | Account path pending; imported path exists |
| Install | Supported local installation reports real device outcome | Account end-to-end path pending |
| Refresh | Renew before actual profile expiry and verify the app still opens | Pending |
| Paid-certificate regression | Import/sign/install same fixture with paid identity; resolve import crash | Existing route; report unresolved/native checks pending |
| Unified host | Runtime starts beneath VexSign, VexSign not installed as a guest | Pending |

Every step needs both success and failure evidence. Cover wrong/expired credentials,
2FA cancellation, sign-out during auth, stale responses, team switching, lost
pairing, missing UDID, portal quotas, unavailable entitlements, expired/revoked
identity, network loss, cancelled signing, full storage, install rejection and
refresh failure. Do not store test credentials or signing material in Git.

### Desktop installer matrix

| Named tool | Identity/version established in this implementation | Free-account primary VexSign install verified |
| --- | --- | --- |
| iLoader | Not audited here | No |
| IPASide | Exact project/version not established here | No |
| Cydia Impactor | Compatibility not established here | No |

Choose one verified tool/device combination for the first slice; expand the matrix
only with evidence. Desktop installer compatibility cannot be inferred from the
new state machine or an unsigned archive.

## Prototype and reference-project boundaries

`EmbeddedContainer/` remains an explicitly labelled **guest-host prototype**, with
its own manual build-only workflow. It is useful for runtime/packaging experiments
but does not fulfill the primary-host architecture and must not be shipped as the
completed all-in-one product. The normal VexSign release pipeline is not replaced.

Use `REFERENCE_COMPARISON.md` as the starting feature inventory for Feather,
FeatherPlus, KSign, RyukSign, MySignReincarnated, Odysseus and the other references.
Do not treat an ambiguous KoSign/KorSign repository match as confirmed. Adapt
specific useful capabilities into shared VexSign modules instead of claiming that
listing a project's name means its features were integrated.

SideSign/SideStore/LiveContainer portions carry AGPL obligations; retain GPLv3
component notices and review GPLv3 section 13 combination/distribution requirements.
No third-party signing source is linked by this foundation step. The native
integration will require the correct aggregate notices and complete corresponding
source before redistribution.

## Next concrete code increment

The pinned isolated dependency/link target and device-only Keychain session-byte
adapter are now implemented; see [NativeSigning](../NativeSigning/README.md).
Compile/link and real-device Keychain validation remain unrun. An in-process
worker-actor coordinator now handles cancellation, commit and retryable cleanup.
A versioned, allowlisted SDK session codec is now written in the isolated native
module, not wired into the app. It excludes cached anisette headers, rejects
unreviewed machine-password material and requires a known unexpired deadline.
Decoded sessions require fresh anisette and server/team revalidation.
The separate durable repository and device-only resume journal are now written,
including reserved-insert recovery and retryable deletion intent. Sixteen new
native tests model restart/failure cases but are unexecuted.
The coordinator now uses this durable implementation directly, with no actor
suspension inside commit/accept or hint/context transitions. Eight coordinator
tests were adapted and six added; none have run natively.
The isolated SDK adapter now calls actual authentication/account/team APIs, with
a transient operation-bound 2FA broker, codec validation and server revalidation.
Hash-checked source overlays suppress the SDK's unconditional debug logging before
credentials can be handled; omitting either overlay fails compilation. The default
transport denies redirects, shared cookies/caches/credentials and keeps system TLS.
Fourteen new adapter/broker native tests are unexecuted; no account calls were run.
The isolated bridge now compiles byte-identical Foundation lifecycle source from
the app alongside the SDK adapter, wiring guarded login, 2FA and resume acceptance
to durable storage. Provider identity/policy/endpoint consent is transient,
instance-bound, expiring and revocable; no default server is chosen. SDK program
categories remain unverified and cannot authorize provisioning results.
Seventeen more native tests are written but unexecuted. This is source-level
integration in the isolated graph, not the ordinary app's linked backend.
A concrete HTTPS header-JSON provider is now written with explicit endpoint
configuration, bounded streaming, strict duplicate-safe parsing, timestamp sanity
checks, redirect denial and normal system TLS. No server is selected; no real
provider requests or twelve newly written native tests were executed.
The isolated `NativeAccountBackend` now assembles actual Keychain stores, the SDK
adapter and configured HTTPS provider behind a secret-free facade. A bridge-held
process-local lease survives cancelled workers; shutdown revokes work/observation
without deleting accepted accounts. Eight assembly tests plus two bridge lifetime/
shutdown cases are written, unexecuted. Six actual app files are copied byte-for-byte.
Next reconcile the confirmed Vapor/Crypto conflict and promote/validate this
backend before enabling account UI; see `NATIVE_DEPENDENCY_RECONCILIATION.md`.
The ordinary app still has no assembled SDK/provider backend or credential UI.
Only after that backend is linked and verified add credential/2FA/team-choice UI. Continue to provisioning,
signing and installation through the existing task system; do not substitute
another account-status mock screen for the end-to-end slice.

### Coding continuation: read-only provisioning preflight

The isolated backend now has a real SDK inventory path for a selected free team,
with Keychain-reference/context checks, fresh anisette consent, account/team
revalidation, retained cancellation-aware workers and non-secret bounded previews.
It never mutates the developer account. Remote certificates are not assumed to
have locally owned keys; listed profiles do not authorize signing. Paid SDK team
categories remain unverified. See `NativeSigning/README.md` for restrictions.

User direction: finish coding before the GitHub Actions testing phase. No tests
or Actions runs were started for this increment. Remaining coding includes durable
CSR/private-key ownership and mutation reconciliation, controlled registrations/
profile creation, profile/entitlement validation, signing/install/refresh wiring
and app/UI promotion; the preflight is not an end-to-end signing implementation.

### Coding continuation: durable signing-identity ownership

The isolated backend now has device-only per-account/team key/CSR ownership,
local prepare/recover and exact never-submitted-draft removal APIs. An atomic
Keychain blob and expected-phase/UUID conditions protect the transition from
prepared to uncertain before a future CSR send. Reconciliation may record only a
single matching public key with matching team and certificate validity; no match
or multiple matches never silently authorize resubmission or revocation. Certificate
recording is not chain/profile/entitlement verification or signing availability.

Sign-out removes the auth session but intentionally retains identity records.
Destructive certified/uncertain-key disposal and rotation need explicit future UI
and recovery policy. No CSR was submitted, no real key generated, and no tests or
Actions runs were performed. Ten native fixtures and a packaging registration
regression are written for the later testing phase. Next coding work is a pinned,
CSR-supplied portal submission boundary (the SDK's current dispatcher is internal),
then controlled provisioning and signing/install/refresh integration.

### Coding continuation: CSR-supplied portal boundary

The saved CSR is now wired through a hash-guarded source addition in pinned
SideSign, not its generate-and-submit convenience method. A separate transient,
revocable, single-use mutation approval and fresh anisette consent precede account/
free-team revalidation, durable uncertain intent and one application-level send.
Receipt adoption validates key/team/time; missing receipt data goes to read-only
inventory, and uncertainty never triggers another CSR or automatic revocation.
The source addition keeps system TLS/private ephemeral transport and bounded
mutation-response accumulation. Request UUIDs do not guarantee server idempotency.

A public read-only uncertain-certificate recovery path and approval revocation API
are written. Six native fixtures/three preparation regressions are written but
unexecuted. No Apple request, build, Keychain write or Actions run occurred. This
is not a trusted signing identity or end-to-end implementation; next coding work
is controlled device/AppID/profile operations and profile/certificate/entitlement
validation before signing/install/refresh and app/UI promotion.

### Coding continuation: profile constraints and ownership projection

A read-only actor projection now obtains profile certificate expectations only
from the exact durable recorded identity, revalidating key/CSR/certificate binding
and time. The basic development-profile policy matches team/prefix, explicit app
ID, target UDID, exact certificate DER, dates, platform and a narrow entitlement
allowlist. It never propagates a profile's wildcard keychain entitlement to an app.

Plaintext constraints and authenticated profiles are different types. The default
CMS gate has **no production verifier** and fails closed; matching a decoded plist
never enables signing. A future verifier must authenticate CMS signature/content,
Apple-authorized provisioning signer chain and purpose, not arbitrary embedded
roots or TLS trust. IPA/nested-code entitlement validation and certificate
trust/purpose/revocation are additional gates, not implied by this policy.

Fourteen profile fixtures, two owned-projection fixtures and one source-registration
regression are written/unrun (34 current first-party preparation inputs). Static
syntax/diff checks only; no network, Keychain mutation, build, test or Actions run.
The normal app is still not integrated. Controlled device/AppID/profile mutations
and actual CMS verification remain coding tasks before signing/install promotion.

### Coding continuation: durable device/App ID registration core

An internal registration executor now requires an exact single-use mutation
approval, fresh free-account authority and inventory checks before add-only
uncertain intent and a single application-level registration call. Read-only
recovery cannot send; absence/ambiguity never resets intent. Case-folded resource
hashes prevent alternate bundle casing from bypassing the journal, while approval
binding preserves exact bundle spelling. A device-only scoped Keychain journal
conditionally commits UUID/phase and stores only hashed resource/remote IDs.

The executor retains exclusive work through actual retirement, checks authority
between hops, supports cancellation/revocation and bounds its deadline by the
supplied authority expiry. No production SDK portal adapter or shared bridge/UI
wiring is supplied yet: those must enforce account/team/context/session binding,
bounded transport, consent deadlines and the existing namespace lease. Profile
creation/CMS verification and signing/install acceptance remain unfinished.
Thirteen native fixtures and one registration regression are written/unrun;
37 current first-party preparation inputs. Static syntax/diff checks only, no
Actions, native builds/tests, real portal operations or Keychain writes.

### Coding continuation: strict registration transport and bound portal

A second source-hashed SideSign addition now provides fixed-endpoint, bounded,
strict-status device/App ID register/list APIs, bypassing permissive SDK defaults.
Six original dispatcher/action/model files are hash-guarded. Inventory requires
explicit device class/status and exact IDs; unknown/expired App ID lifetime is not
an enabled registration. The journal's UUID now accompanies the single application
send, with no claim of server idempotency. No retries, revocation or quota cleanup.

An internal bound portal connects those APIs to the registration executor. It
requires exact owner/context/session binding, live authority/consent callbacks,
fresh headers, fresh free-team revalidation and a retained supplied account lease;
its authorization cache is short-lived and invalidatable. Shared bridge/public/UI
wiring remains a coding task, not automatically enabled by this adapter. Native
compilation, real HTTP/Apple dialects, cancellation/lease behavior and CMS/profile
signing acceptance remain unvalidated. Seven new policy fixtures/two preparation
regressions are written/unrun; 40 first-party preparation inputs plus two SDK source
additions. Static checks only; no tests/builds/Actions or actual Apple mutations.

### Coding continuation: shared registration backend integration

The isolated backend now has exact-context registration approval/execute/revoke
and separate read-only recovery APIs. The bridge gates registration against other
account work, supplies the real factory namespace lifetime and live context/consent
callbacks to a per-worker bound portal, and delegates only remaining user approval
lifetime. Sign-out/shutdown/provider-consent revocation invalidate pending grants
and cancel work without deleting registration/identity journals. Cancelled workers
retain their slot/lease through retirement; a cancelled result is not no-effect
proof. Public result metadata does not export raw portal/device IDs.

Seven new fake bridge fixtures and one preparation regression are written/unrun;
41 first-party inputs plus two SDK source additions. Static grammar/syntax/diff
checks only, no builds/tests/Actions, Apple calls or Keychain mutations. Normal
app/UI availability remains notIntegrated. Profile creation/CMS, certificate and
IPA acceptance, signing/install/refresh and primary-host integration remain coding
and later native/device validation tasks.

### Coding continuation: durable profile creation/recovery core

Internal profile scope binds the owned identity projection, exact target and
freshly resolved remote resource IDs. Case-folded, length-delimited logical hashes
prevent case/remote-ID aliases from bypassing uncertainty, while transient approval
binds exact values. Creation journals uncertain intent before one application send;
read-only recovery cannot create/regenerate/delete. Adoption requires a unique
CMS-authenticated, constraint-matched envelope, preserving its exact signed bytes.
The default missing CMS verifier blocks approval and store/portal I/O entirely.

A separate device-only scoped Keychain journal commits operation UUID/uncertain
phase to observed profile UUID/CMS/remote-ID hashes. No raw profile/UDID/bundle,
credentials or private key is stored; no reset/delete interface. Ten fake fixtures
and one registration regression are written/unrun (45 first-party inputs). Static
checks only; no native builds/tests/Actions, CMS verification or Apple/Keychain
operations. Production profile transport, real CMS verifier and bridge/owned remote
binding remain unfinished; app capability is still notIntegrated. Renewal, final
certificate/IPA acceptance and signing/install/refresh are not implied by this core.

### Coding continuation: bounded explicit profile transport

A third hash-guarded SideSign source addition separates explicit-ID listing/manual
download from one-device/one-certificate limited creation. App-based SDK download
(which may generate a team profile), regeneration and cleanup are never used.
The shared internal bounded transport now has seven fixed Apple actions; profile
response/CMS/count/aggregate limits and strict required metadata prevent silently
empty or partial inventories. Known pagination markers fail closed; actual Apple
completeness/dialects still require later validation.

Native selection binds exact App ID/bundle and list/download UUIDs; the core then
matches the CMS-authenticated UUID before adoption. Existing-UUID selection is
read-only, not creation authority. Missing real CMS verification still blocks
profile executor I/O. Bound profile authority/resource resolution and shared
bridge/UI integration remain coding tasks, not inferred from transport methods.
Eight policy plus two core fixtures and two preparation regressions are written/
unrun; 47 first-party inputs plus three SDK additions. Static checks only: no
build/test/Actions, Apple or Keychain operations. Signing readiness/notIntegrated
is unchanged; CMS, certificate/IPA acceptance and install/refresh remain unfinished.

### Coding continuation: account-bound profile portal and owned resources

An internal profile portal adapter now binds exact owner/context/session and live
callbacks, retains the supplied namespace lifetime, obtains fresh headers and
revalidates free-team authority. Its resource policy requires exact enabled device/
App ID remote bindings, current App ID expiry and unique owned certificate ID/DER.
The identity actor now returns recorded identity UUID/certificate ID with validated
key/CSR/cert target material through one read-only projection. Stale projections,
resource aliases and duplicate certificate bytes cannot authorize creation.

Default CMS absence blocks adapter construction before I/O. Authorization is short-
lived/nonce-protected; public bridge/UI assembly remains unfinished. Certificate
inventory still uses legacy SDK read transport with post-decode bounds only, and
certificate trust/purpose/revocation are not asserted. Those limitations plus actual
CMS verification must be addressed before production promotion. Seven policy and
one default-gate fixtures/one preparation regression are written/unrun (50 first-
party inputs, three SDK additions). Static checks only, no tests/builds/Actions or
actual Apple/Keychain/cryptographic operations. App capability stays notIntegrated.

### Coding continuation: bounded certificate inventory for profiles

The bound profile portal now requires a dedicated certificate inventory method,
not the permissive SDK fetch. A fourth source-hashed addition uses the pinned legacy
plist certificate-list action with strict transport/status/schema, required actual
certificate ID/material, no dropped malformed records/request-ID guessing, explicit
pagination checks and response/material caps. Its compatibility with current Apple
responses is unvalidated (the SDK convenience uses another JSON services endpoint);
unknown dialects block without fallback. This is raw material transfer, not DER,
chain, purpose or revocation proof. Other legacy SDK read paths are unchanged.

Seven policy fixtures/two preparation regressions are written/unrun; 52 first-party
inputs plus four SDK additions. Static checks only; no tests/builds/Actions, Apple
or Keychain operations. Actual CMS verification and profile backend assembly remain
unfinished, and normal app signing capability stays notIntegrated.

### Coding continuation: concrete CMS signature/trust verifier, not promoted

A public-Security/CryptoKit verifier is written for a strict attached DER CMS v1,
single-signer SHA-256/RSA subset. It binds payload digest, mandatory unique signed
attributes, exact signature bytes and issuer/serial signer selection before
releasing payload. System BasicX509 trust uses current time with network disabled,
rejects user trust overrides and requires the reviewed three-link provisioning-
signer CN/issuer policy plus pinned production Apple root hashes. No private SPI,
arbitrary embedded anchors or signingTime backdating. Unsupported forms reject.

Immutable Apple source/root review is registered in apple-cms-policy-review.json.
The verifier is uncompiled/unrun, has no real positive Apple CMS fixture, is not
selected by default and is not asserted equivalent to all private Apple policies.
Eight deferred fixtures/one preparation regression are written (57 first-party
inputs plus four SDK additions). Source/public-certificate inspection and static
checks only; no CMS/trust/signature execution, keys, Keychain, Apple requests,
builds/tests/Actions. Profile/public bridge assembly and final signing acceptance
remain unfinished; normal app capability stays notIntegrated.

### Coding continuation: profile account facade and shared worker authority

Public isolated-backend profile approval/create/reconcile/revoke APIs now assemble
the durable executor and bound portal. Targets supply registered resource selections,
not arbitrary certificates; current owned identity supplies certificate ID/material,
and fresh exact portal resource checks remain mandatory. Opaque grants bind exact
target/owned request, owner/context/generation/epoch for at most 120 seconds, are
consumed before asynchronous setup and cannot renew themselves. Selected existing
UUIDs are recovery-only. Receipts expose UUID/expiry only, never CMS/session/key
bytes or readiness. Future signing must internally recover/retain the artifact.

Ordinary auth/preflight/identity/certificate/registration operations now also check
the profile worker slot. Revoke/sign-out/shutdown cancel/invalidate without early
slot/lease release. Fresh context/consent/owned callbacks, expiry caps and final
checks protect the per-worker executor; bound authorization clears on success/error.
No journal reset, automatic renewal, remote cleanup or create-on-recovery fallback.

**Default public CMS gate remains closed** pending native validation/promotion.
No normal app enablement, real CMS execution or production compatibility claim.
Twelve native fixtures/one preparation regression written/unrun; six changed Swift
files grammar-checked initially, Python syntax/diff checks only. Current provenance
59 first-party inputs plus four SDK additions; native tests/builds/Actions deferred.

### Coding continuation: main-file inspection, not complete IPA authorization

Actual main-executable bytes now receive bounded thin-ARM64 MH_EXECUTE header,
load-command and code-signature superblob inspection. Nonzero encryption cryptid
rejects without decrypting. Duplicate/overlapping slots and unsupported DER
entitlements reject; extracted XML is untrusted requested claims, not original-
signature authentication. Info metadata and the narrow entitlement policy bind
exact bundle/executable/platform; generated identity/keychain/debug claims come
from the authenticated profile, not arbitrary source entitlements. XML entity/
nonstandard DTD inputs reject before OS plist parsing; native parser resource
behavior remains unvalidated.

Authenticated profile output now retains its validated certificate hash/device;
the internal handoff candidate requires those exact bindings, team/app/group/UUID,
CMS hash and expiry, retains exact source/profile/entitlement bytes, and expires
within 30 seconds. No private key/export/signing API or execution authority is
provided. This is NOT whole-IPA acceptance: complete ZIP/resource/alias/symlink/
nested-code inspection, full Mach-O semantics, certificate trust/purpose/revocation
and fresh execution/install-target authority remain required before any signing.

Ten native fixtures/one preparation regression written/unrun; 62 first-party
inputs plus four SDK additions. Four Swift files grammar-checked; Python syntax/
diff only. No native tests/builds, real file inspection/signing, key/Keychain,
provider/Apple requests, Actions or UI/CMS promotion; `notIntegrated` unchanged.

### Coding continuation: actual ZIP record/namespace inventory, content pending

Strict bounded ZIP32 indexing now binds EOCD/central/local/descriptors, requires
complete nonoverlapping local-record coverage, and rejects unsafe/aliased names,
file-directory conflicts, links, encryption, ZIP64 and unsupported extras. Source
hash and exact compressed ranges are retained; ASCII/single-disk/stored-deflate
support is intentionally limited. No extraction or permission materialization.

Single-main-app namespace selection requires exact Payload/root/Info.plist and
rejects named unsupported nested executable layouts/outside metadata. This is NOT
whole-IPA acceptance: mandatory decoding/actual CRC/all-entry content validation,
disguised executable detection and later nested-code handling remain unfinished.
Index/layout artifacts grant no signing/install authority or public UI readiness.

Nine fixtures/one preparation regression written/unrun; 65 first-party inputs plus
four SDK additions. Three Swift grammar checks, Python syntax/diff only; no native
build/tests, real ZIP/decompression, Apple/provider/Keychain/signature operations
or Actions. Implementation continues first; CI remains deferred by user request.

### Coding continuation: all-entry checksums/content and public local inspection

Stored/raw-deflate decoder source now checks bounded output, progress, termination,
library-reported input consumption and CRC-32. Input ranges are borrowed for
inflation; scratch buffers are fixed and output is capped before append. Index/CRC/
decode loops observe cancellation. Native Compression compatibility and trailing-
input behavior are unvalidated; no decoder/fixture has executed in this phase.

Content inspection builds its own complete ZIP index/layout, checks every entry's
actual decoded checksum/hash, binds Info/main selection and rejects extra Mach-O/
fat/static-library bytes disguised as resources. Exact Info/main bytes plus source
and entry hashes stay internal. No extraction, original-signature/publisher trust,
certificate authority, signing, install or full nested-code support is granted.

Public local inspection returns metadata only, executes off caller actors, holds
a process-local inspection slot until actual retirement and sanitizes failures.
It does not need an account or touch provider/Apple/Keychain/network/filesystem.
This remains isolated-module source, not normal-app UI/link integration. Eleven
native fixtures/one preparation regression are written/unrun; 69 first-party
inputs plus four SDK additions. Static checks only; builds/tests/Actions deferred.

Requested native signing/install/refresh/UI integration is NOT completed by this
stage: certificate trust/purpose/revocation, protected identity/artifact handoff,
concrete signer/output verification, paired device confirmation, quota-safe renewal
and normal-app module/UI assembly still need implementation. Existing imported-
certificate services were reviewed, not relabeled as native-account capability.
Default CMS/readiness/UI gates stay closed; do not claim end-to-end completion.

### Sequential completion: concrete development trust and pre-sign handoff

Development purpose parsing and a public-Security chain evaluator are written.
Only the exact team/development role/code-signing EKU/non-CA leaf with WWDR and
pinned three-link Apple chain is supported. Positive cached revocation is required;
network is disabled, missing status rejects, and evidence cannot be cached as a
signing permit. Scoped online disclosure/issuer assembly remains unfinished.

Read-only handoff assembly preserves the complete archive binding, fresh ownership,
revalidated CMS/UUID, concrete certificate evaluation, authority callbacks/deadline
and namespace lifetime. It does not delegate a key, sign, install or infer approval.
The convenience SDK signer was reviewed and not wired: first-profile fallback,
group rewriting/key exports and hardcoded issuer require a strict adapter plus
output verification. Immutable review hashes are in development-certificate-review.json.

Full checklist: docs/NATIVE_SIGNING_COMPLETION.md. Ten fixtures/one prep regression
written/unrun; 74 first-party inputs plus four SDK additions. Static checks only,
no native compiler/tests/trust/keys/Keychain/Apple/provider/Actions. Normal app,
CMS default and readiness/UI promotion remain blocked; all-work completion is NOT
claimed. Protected execution/install/refresh/normal-app/UI stages are unfinished.

### Online status consent/issuer step (source only; normal-app integration pending)

Public native-backend status consent/revoke/evaluate APIs now use exact single-use
owner/context/identity/certificate/generation/epoch grants (<=120s). Offline Apple
purpose/chain validation precedes consumption/network enablement; positive system
OCSP/CRL is mandatory, never best-effort. No grant retains offline-only behavior.
Revocation invalidates authority without early OS-worker slot/lease release. All
ordinary bridge busy checks include status workers; revocation/sign-out invalidate
before actor hops. Owned certificate projection has no fabricated app/device IDs.

A pinned reviewed public WWDR G3 issuer candidate is supplied, not installed as an
anchor. Other generations block. Public receipt is metadata, not a signing permit.
Read-only handoff can pass scoped status authorization; no key delegation/signing,
install, refresh or normal-app UI enablement is implied.

Further engine source review identified dual XML/DER claims and noncanonical true
BOOLEAN encoding in the pinned DEREncoder. Corrections/output proof are required
before engine wiring. Source hashes are recorded. Ten fixtures/one prep regression
written/unrun; 77 first-party inputs plus four SDK additions. Static checks/public-
cert fingerprint inspection only, no native compiler/tests/trust/keys/Keychain/
provider/Apple/Actions. See completion ledger for remaining implementation.

### Output consistency/transport primitives (not artifact release)

The native graph now includes independent bounded CodeDirectory SHA256 page/special
slot consistency, exact-signer detached CMS signature verification with a separate
role from attached provisioning CMS, and deterministic stored ZIP32 generation with
independent namespace/index and all-record CRC/decode readback. None constructs an
installer artifact or replaces full Mach-O/resource/mutation/authority verification.
Hash-locked preparation corrects all three upstream DER true-boolean branches,
preserves originals and records both hashes. Native execution remains deferred;
unsigned exec flags still fail the strict directory policy. 81 first-party inputs,
four SDK additions and one correction. Remaining stages stay closed in the ledger.

### Composed claims and resource consistency (source only)

Output checks now connect canonical dual entitlement claims, strict independently
encoded all-file resource seals and original/output archive mutation consistency.
Every output record is CRC-decoded; original resources/Info.plist cannot mutate or
vanish even if a malicious engine reseals them. Main/profile/root signature metadata
are the only mutation roles. Expected profile bytes are not authenticated here;
the future execution boundary must supply the fresh authenticated candidate.
Five-slot superblob consistency composes claims, directory hashing and detached CMS
signature primitives. It rejects alternate/duplicate/overlapping/gap/hidden slots.
Requirement bytes are hash-bound, not semantically authorized. Neither resource nor
signature consistency receipts are verified install artifacts. Full Mach-O mutation
and requirement policies, live protected execution, workspace/sealer and actual
app services are still pending. 86 mapped inputs; ten native fixtures and one prep
regression written/unrun. Static checks only; no readiness/default-gate promotion.

### Image-bound mutation subset (not full loader authorization)

Existing-signature thin ARM64 images now have bounded segment/VM/section mapping,
entry-in-instruction-section checks and terminal linkedit signature bounds. The
mutation checker preserves all pre-signature bytes except exact linkedit sizes and
signature offset/size; no code/data moves, insertion or other-command rewriting.
Both images are parsed independently; actual ranges feed the combined signature
consistency verifier. Unknown preserved commands still need separate dyld/dependency
and linkedit-reference authorization. Requirements, private signer/workspace/sealer,
install/renewal/UI remain pending. Five unrun fixtures/one prep regression, 88 input
mappings; only static checks, no native execution or readiness-gate change.

### Native designated requirements (source-only narrow policy)

The composed signature checker now requires one canonical designated expression:
exact identifier AND leaf-position-zero certificate digest. Immutable Apple maker,
interpreter/header/type sources and hashes are recorded in the review manifest.
Exact serialization excludes extra clauses/OR/skip/unknown semantics and nonzero
padding. SHA1 is used only because it is Apple's legacy requirement representation;
exact DER plus RSA/SHA256 CMS and fresh certificate/profile/context checks remain
separate obligations. Leaf renewal changes this requirement; upgrade/keychain/
refresh continuity needs native/device validation. Five fixture methods and one
preparation regression are written/unrun; 91 source inputs. Protected signer,
loader/dependency/linkedit-reference policy and install artifacts remain gated.

### System-only loader command envelope

Both original and output now pass a fail-closed command whitelist with canonical
system dependency paths, exact dyld/iPhoneOS metadata, bounded pre-signature linkedit
references and limited nlist/symtab/dysymtab bounds. Unknown/RPATH/environment and
non-system dependency dialects reject. Loader/nlist ABI source hashes are recorded.
This validates envelope/ranges only: bind/rebase/export/fixup payload interpretation,
actual device dependency availability and platform execution are NOT proven.
Complete loader semantics remain blocking before protected execution/sealed output.
Five unrun native fixtures/one prep regression; 93 source inputs, static checks only.

### Legacy dyld pointer actions (narrow dialect, not complete loader approval)

Legacy stream ranges now feed a bounded state machine with canonical ULEBs,
writable aligned file-backed pointer targets, in-image rebase/helper values, positive
system ordinals and bounded symbols. Repeated/overlapping writes, overflow, missing
state/termination, unsupported types/flags/addends/threaded forms reject. Rebase
followed by lazy bind of the same helper is explicitly allowed, not arbitrary overlap.
Weak/nonempty-export streams and export-trie/chained commands now fail closed rather
than pass on range checks. Remaining payload semantics/platform behavior and the
actual signer/install/refresh/UI pipeline remain pending. Nine native fixtures and
one prep regression written/unrun, 95 inputs; static checks only, no gate promotion.

### Regular export trie metadata subset

Legacy and dedicated export commands now share a bounded canonical trie decoder.
Regular/weak-regular terminals must map into pre-signature file-backed image data.
Cycles/shared nodes, ambiguous branches, duplicate symbols, unsupported flags,
interior gaps/hidden payload and excess padding reject. Alternate nonempty legacy
and dedicated authorities are forbidden. Chained fixups remain unsupported, not
range-only accepted. Six new native fixtures and updated loader integration are
unrun; 97 sources, static checks only. No symbol resolution/platform acceptance,
protected signing, sealed output or app-service integration is asserted.

### Restricted chained pointer metadata

LC_DYLD_CHAINED_FIXUPS now uses a bounded format-6/format-1 uncompressed decoder.
Metadata ownership, imports/string starts, segment VM/page geometry and pointer
chains are validated; special/weak/addend/auth/other formats and multi-start pages
reject. Positive import ordinals stop at 240 per reviewed Apple dyld ABI, not 253.
Targets remain writable/non-executable file data; mapped rebase and import indices
are checked without applying fixups or loading libraries. Classic pointer streams
cannot coexist. Source revision/hash is recorded. Seven unrun fixtures, 99 inputs,
static checks only. Full platform semantics, actual signer/artifact/install/refresh/
UI wiring remain unfinished; default capability gates are unchanged.

### Composed read-only archive auditor

A single source path now binds whole packaged output to the original handoff and
refreshes owner/context/profile/certificate proofs before/after detached output
verification. It composes resource/CRC, image/loader, claims/requirements, directory
and CMS checks and compares shared byte hashes; original deadline/lifetime remain
binding while cancellation workers retire. Function-start/data-in-code metadata
are decoded too. The resulting redacted audit has no bytes/URL/private key or
installer authority. Default CMS/capability gates and normal app graph remain
unchanged. Native positive trusted audit fixtures/platform behavior and protected
signer/workspace/sealed install output remain pending. Four metadata fixtures and
one prep regression unrun, 102 sources; static checks only.
