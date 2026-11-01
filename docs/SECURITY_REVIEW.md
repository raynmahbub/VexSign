# Security review — VexSign

Scope: the areas the app exposes to untrusted input and secrets handling —
IPA/TIPA/deb archive extraction, repository (source) URLs and redirects,
certificate/password handling, downloaded tweak and dylib validation,
repository transport security, security-scoped resources, diagnostics
exposure and temporary storage lifetime.

Status legend: **fixed** (change landed in this pass), **verified** (reviewed,
adequate as-is), **documented** (accepted risk / behavior explained).

## 1. Archive extraction (IPA / TIPA / deb / tar) — FIXED

**Attack surface.** `Decompression.swift` untars `.deb` payloads and tweak
archives; `AR.swift` parses `ar` archives; `Zip` extracts IPA/TIPA bundles.
Archive entry names are attacker-controlled strings.

**Findings & fixes.**

- *Path traversal (`../` and absolute names)* — the tar loop previously kept a
  single `standardizedFileURL` prefix check. It now rejects, before any write:
  absolute paths, any `..` component, `~`-relative names, backslash separators
  (Windows drive/path tricks), and NUL bytes (`_isSafeArchiveEntryName`).
  The prefix check stays as a backstop. Skipped entries are logged under the
  `Security` log category (surfaced in the Diagnostics Center).
- *Symlink / hardlink / device / FIFO entries* — only `.regular` files and
  `.directory` entries are materialized; every other entry type is skipped
  and logged. A symlink can therefore never be written into the extraction
  tree, which was the classic "link now, write through it later" escape.
- *Zip extraction* — handled by the `Zip` dependency (ZIPFoundation-based);
  its sanitization was reviewed and it strips absolute paths and `..`
  components on extraction.

**Tests.** `StabilityAndArchitectureTests.testUnsafeArchiveEntryNamesAreRejected`.

## 2. Repository URLs and redirects — FIXED / VERIFIED

**Findings & fixes.**

- *Transport policy* — repositories must now use **HTTPS** end to end:
  adding a source (`FR.handleSource`, `Storage.addSource`) and every refresh
  (`SourcesViewModel`) validate the URL through `SourceURLPolicy`. `http://`
  is only allowed after an explicit, clearly-labeled opt-in
  (Settings → Security → *Allow Insecure HTTP Sources*, default off).
  Non-HTTP(S) schemes (`file:`, `ftp:`, …) are never accepted. Restoring a
  user's own backup re-adds their saved sources, but those sources are still
  not refreshed until the opt-in is enabled.
- *Redirects* — `URLSession` follows redirects but never changes the scheme
  except to HTTPS upgrades announced by the server; ATS applies. Catalog
  fetches use the same default `URLSession` with ATS on (no exceptions are
  registered anywhere in the app — verified by grep).
- *Catalog content* — repository JSON is decoded with a strict
  `JSONDecoder` into `ASRepository`; decode failures are recorded per source
  and never crash the store. Raw payloads are cached to disk only as the
  already-fetched JSON (no headers/credentials are persisted).

## 3. Certificate and password handling — VERIFIED

- Certificate passwords live in the **Keychain** (`CertificateSecrets`,
  `SecureSecretStore`) with read-through migration that *fails closed* if the
  Keychain is unavailable; the Core Data `password` field is nulled after
  migration.
- No password values are logged (grep audit of all `Logger`/`print` sites —
  only error descriptions and certificate names appear).
- The `vexsign://import-certificate` URL scheme accepts p12/profile/password
  in the query string — this is by design (compatibility with Feather), but
  passwords never reach logs, history or the task center.
- **Private keys never leave the device for a status check.** Revocation
  evidence comes from `CertificateInspector` (`SecPolicyCreateRevocation` with
  `kSecRevocationOCSPMethod | kSecRevocationRequirePositiveResponse`), which
  sends certificate identifiers to the responder and nothing else. The legacy
  multipart upload to a third-party checker was deleted in R3; its stored
  verdicts and its consent switch are erased on launch
  (`CertificateStatusManager.legacy*Key`), because a verdict produced from an
  uploaded p12 is not evidence this app can stand behind.

## 4. Downloaded tweaks and dylibs — VERIFIED / DOCUMENTED

Downloaded `.dylib`/`.deb`/`.framework` components are stored in the app
sandbox and injected at sign time; they are never executed by VexSign
itself. Mach-O parsing (`MachO/`) is defensive against malformed binaries
(bounded reads, type-safe header access). Injection always happens under the
user's own certificate, so a malicious dylib's blast radius is the signed
app — VexSign adds no entitlements the profile doesn't grant.

## 5. Security-scoped resources — VERIFIED

All `startAccessingSecurityScopedResource()` call sites are paired with
`defer { stopAccessing… }` (FR.swift certificate import/check, HomeView
drag&drop, OnboardingView import). `BackupArchive` cleans its work directory
in `deinit`.

## 6. Diagnostics and backups — VERIFIED

- The diagnostics bundle (`DiagnosticBundleExporter`) ships sanitized logs
  and certificate **metadata** only — no private keys, no passwords
  (explicit `_sanitize` pass over logs, plus summaries that exclude
  secrets).
- Backups are **always encrypted** (R11). A random per-backup content key
  encrypts the payload with AES-GCM; that key is wrapped either by a PBKDF2
  (SHA256, 200k iterations, 16-byte salt) key derived from the user's password
  or by a 32-byte device key held in the Keychain, never both. A backup that
  includes certificates requires a password of at least 8 characters, typed
  twice; a passwordless backup is device-bound and cannot be restored
  elsewhere. Older `VEXBK0` plaintext files still restore, behind a warning
  that names what they contain.

## 7. Temporary storage lifetime — FIXED

- Signing (`VexSigning_*`), backup (`VexBackup*`) and diagnostics
  (`DiagnosticBundle*`) working directories live under the system temp
  directory, which iOS purges under pressure — but a hard kill previously
  left complete app bundles there indefinitely.
- `TempStorageSweeper` now runs during `EcosystemMaintenance` (launch and
  background refresh) and removes VexSign-owned temp directories older than
  24 hours. It only touches well-known prefixes and never an in-flight run.
- `SigningHandler.clean()` also removes moved-but-unregistered bundles so
  they cannot leak from a failed sign.

## 8. Repository snapshot cache — VERIFIED (new)

The offline catalog cache (`Application Support/SourceSnapshots/`) stores the
raw catalog JSON per source, capped at 64 snapshots, evicting by age, and is
pruned to installed sources after every refresh. It contains no credentials.

## 9. Community certificate catalogue — CONTAINED (new)

Settings → Certificates offers a catalogue of shared Apple Developer identities
published by a third party at `sideloading.net`, together with their passwords.
These are not VexSign's certificates and they are not official in any sense.

What the app now guarantees:

- Nothing is downloaded until the user has read a disclosure that names the host
  and explains that the identity and its password are public, that anyone can
  sign an app claiming to come from it, and that its owner or Apple can revoke
  it at any time.
- The acknowledgement is stored against the host name, so pointing the catalogue
  at a different host invalidates it. "Turn Off This Source" clears it.
- Each import is confirmed individually and names the certificate and the host;
  the confirmation states that the password is downloaded with the certificate.
- Downloads are `https` only, go to one host, and are capped at 16 MB.

Residual risk, accepted: the files themselves cannot be authenticated — there is
no signature or pinning to check, only that the password opens the p12 and that
the profile matches. A user who imports one of these identities is trusting
`sideloading.net`, and the certificate can be revoked out from under every app
signed with it. The UI says all of this before the first byte is downloaded.

## Remaining recommendations

1. Pin or verify repository TLS certificates (e.g. allow users to "trust" a
   source's cert fingerprint) — currently standard ATS validation applies.
2. Add a download-size cap for catalog JSON (defense against a hostile
   multi-gigabyte "catalog").
3. Consider per-source cookie isolation if authenticated sources ever share
   a session (not the case today; `NBFetchService` sends only explicit
   headers plus an optional `X-API-Key`).
