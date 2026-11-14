# Signing/library acceptance checklist

**All observations below are pending.** This checklist accompanies the
[signing/library implementation report](../Architecture/signing-library-reliability.md),
not a passed acceptance record. It supplements [device testing](DEVICE_TESTING.md).
Do not put identities, passwords, personal provisioning profiles, pairing records,
raw UDIDs or private device logs into Git, Actions artifacts or public reports.

## 1. Candidate provenance and Apple build gate

1. Record the exact reviewed candidate revision and full working-tree state. The
   implementation commit is `bf063e778cc2bdf3bdbcd5a84646cc6b95b6d285`, based on
   `8daf7e7e577cd05597a29d69952ea2c80e31e3ee`, with subsequent integration of main
   `725a2769be00ad60542102f472bbb879c8136f86`. Test the actual integrated PR head;
   historical CI for an earlier revision does not validate this candidate.
2. On a Mac with the repository's supported Xcode/iOS SDK, run the normal app
   build and simulator XCTest target (`make bootstrap`, `make test`, `make VexSign`).
   Run the existing companion/platform checks when relevant. Confirm that the
   public-only `CodeSignatureCMSFixture.json` is bundled in the XCTest resources.
3. Publication and main integration have been explicitly authorized. Use the
   existing CI full workflow to validate the exact integrated published revision;
   do not substitute old results or infer physical-device acceptance. The Linux
   native regression job does not compile Swift or Objective-C++/Security code.
4. Inspect compiler/concurrency diagnostics rather than suppressing new warnings
   or weakening tests. Run `ProvisioningAdmissionTests`, `SignatureSealTests`,
   `ComponentSigningResolverTests`, `SigningReadinessTests`, `SigningInventoryTests`,
   `SigningIdentityLeaseTests`, `SigningSourceAndRemovalTests`,
   `CredentialMigrationDiagnosticsTests`, `StagedAppDeletionTests`,
   `LibraryGridSwipePolicyTests` and `LibrarySwipeLayoutTests` as part of the full
   target, not instead of the other existing tests.
5. Build/sign VexSign for a spare trusted iPhone with test-only authorized assets.
   Retain the actual signed candidate's SHA-256 privately. An unsigned debug IPA
   must first be signed; neither its packaging nor simulator success is device
   installation acceptance.

Record device model, iOS version, candidate identity and observed results. Never
invent missing timings, trust results or install confirmations.

## 2. Safe fixture preparation

Use harmless applications you own or are allowed to test, with their original
identifiers. Keep a private list of source/archive hashes, versions and expected
main/extension identifiers. Prepare, where available:

- one current Apple-issued identity/profile pair covering the main application;
- separate authorized profiles/identities for retained extensions on the same team;
- a legitimate wildcard and an exact profile that both cover a test component;
- an incompatible explicit App ID and a different-team/leaf profile for negative tests;
- an expired profile/certificate and a device-limited profile for another test device;
- a copy with a known optional share/widget extension and one with a required or
  unknown extension point; keep their expected functionality documented;
- one valid executable framework, a genuine resource-only `BNDL` bundle, and a
  deliberately incomplete/unreadable framework copy for negative tests.

Synthetic non-Apple test CMS verifies low-level behavior only. It must **not**
be accepted by production profile authentication, reported as Apple-issued, or
used to claim a successful install. Do not alter a primary device's clock to
force expiry. If a scenario needs an instrumented test build or a second device,
record that requirement and leave it blocked until available.

## 3. Admission, readiness and the reported screenshot

| Scenario | Required observation |
| --- | --- |
| Main App ID mismatch | Import/select a profile for another explicit identifier. The original app/extension IDs remain unchanged, readiness is Blocked, setup explains the profile App ID and target, Start Signing is disabled, and Review Signing Issues opens actionable details. Execution remains Not run unless a run actually began. |
| Genuine compatible positive case | Import the complete matching identity and current authentic profile. Every retained component is resolved; Ready/Warning, checklist and review agree. Confirm exact profile UUID, certificate fingerprint/team and both expiry windows before approval. |
| Missing certificate vs missing/inaccessible key | Exercise absent PKCS#12, a certificate without its key, wrong password and locked/unavailable Keychain using test assets. Distinguish these failures; none becomes an empty-password fallback or enabled Sign action. |
| Authentication | Raw XML/binary plists, unrelated XML inside bytes, malformed/truncated/modified/self-signed CMS and unsupported signers are refused. A positive real Apple profile must be accepted by the Security bridge before signing eligibility can be claimed. |
| Leaf/profile membership | Matching display names/team strings do not excuse a certificate not listed by the profile. A profile certificate is never substituted for the PKCS#12 leaf/key proof. |
| Dates and mode | Expired/future assets, unknown validity and unsupported distribution-only profiles cannot approve device signing. An expired primary-profile row date must not be mislabeled as the leaf's expiry when a current compatible additional profile exists. |
| Device and platform | Device-limited profiles require actual matching target evidence. No selected device is ambiguous, another device is invalid. An iPhone pairing record cannot prove a Watch UDID. Simulator/macOS/wrong-platform binaries are not device-signable. |
| Required entitlements | Unauthorized required groups/capabilities block. Boolean false and numeric zero remain distinct. Unsupported DER/value shapes are explicit refusals, not silently empty entitlements or copied whole-profile grants. |
| Automatic and manual selection | Exact valid matches rank before valid wildcards. Another valid imported combination can be used automatically; disabling Automatic or choosing a per-component preference restricts that choice. Stale/incompatible manual preferences block without substitution. |
| Same-team multi-identity components | Resolve a main app and extension using different valid identities/profiles on the same team. Every component's own embedded profile, signer and entitlements must match the review. Different-team containment fails. |
| Freshness | Change options/identity/profile selection during inspection, foreground the app after file changes, and press Check Again. Checking/late/cancelled results cannot enable a previous approval. |
| Approval race | Replace source bytes, profile/PKCS#12 bytes, saved password, device evidence or eligibility after review but before execution. Final revalidation must refuse changed inputs; approval is not an authorization token that bypasses authentication. |

The original screenshot's installed revision and exact imported files were not
available for reproduction here. Record them privately before calling the
installed issue resolved. An incompatible profile should still produce a refusal;
only compatible assets justify a positive result.

## 4. Nested code, compatibility removal and verification

| Scenario | Required observation |
| --- | --- |
| Recursive discovery | Place retained extensions/apps/frameworks/dylibs in valid non-default nested locations. Inspect the complete manifest; incomplete discovery, links/case collisions/unowned executable code cannot be silently skipped. |
| Framework distinction | A valid executable framework signs and verifies. A proven resource-only bundle is not treated as executable code. An unreadable/missing/malformed framework executable blocks; a read error is not a resource-only classification. |
| Signing order | In a test build's non-secret diagnostics, observe libraries before enclosing bundles, nested bundles before parents and the main app last. Profiles and final entitlements are embedded before seals. |
| Compatibility off | Leave default compatibility/removal options off with an uncovered extension. The extension remains in the source and signing blocks; identifiers/capabilities are not changed to make it pass. |
| Explicit optional removal | Enable removal for an eligible optional share/widget extension. Review names the exact path and lost functionality, and requires explicit consent. The working copy alone changes; the retained tree is revalidated. |
| Required/unknown/referenced extension | A required/unknown extension point, nested app, retained binary/plist reference, unsupported scan or unreadable file prevents removal. Do not repair guessed references or remove a Watch tree wholesale. |
| Changed removal consent | Add/change an incompatible optional extension after approval, or replay saved settings in automation. It must not silently approve a different removal list. |
| Tamper rejection | Under an instrumented test fixture, change a page, Info.plist, resource, nested seal, entitlement/requirements blob, CMS, signer or embedded profile before verification. Fresh verification must fail and no signed artifact is registered. |
| Incomplete evidence | A fresh run with incomplete evidence cannot register a signed copy even with a nonmandatory preflight override. Import-only inspection must not be labeled cryptographically verified. |
| Source safety | Cancel/refuse at copy, customization, signing, verification and registration boundaries. The original imported artifact/archive hash stays intact, and only the owned failed working/output copy is cleaned. Native cancellation is cooperative, not forced interruption. |

## 5. Compact swipe and stored-artifact deletion

Try Downloaded/imported and Signed records in compact list, cards and icon grid at
narrow/wide widths, rotation and supported Dynamic Type sizes. Include Reduce
Motion, disabled appearance animations, VoiceOver and a longer localized Delete
label. Record screenshots and actual hit-testing, not just hosted size assertions.

| Scenario | Required observation |
| --- | --- |
| Reveal/close | Left reveals the compact trailing red trash/caption; right closes. The icon, useful app information and expiry stay visible; no oversized red panel or offscreen leading content. Full swipe never deletes. |
| One action and tap dismissal | Open A, reveal B, then tap A/content/navigation controls. Only one row remains open. The first closing tap cannot also navigate or invoke Sign/Install. Tap outside the action to close; the Delete control still works when revealed. |
| Accessibility | Delete/Close are named actions, destructive action opens the same confirmation, tap target is usable, text is not clipped, focus remains understandable, and Reduce Motion avoids spring movement. |
| Existing library controls | Edit/Done, Add, title, search, section selector/counts, expiry indicators, empty states, selection, leading workflow actions, context menus and bottom navigation still work. Search/scope/layout/edit changes retire stale reveals/selections. |
| Confirmation/cancel | Delete identifies the stored-copy scope. Cancel changes nothing. Confirm removes exactly that record/artifact, never an installed app, source archive, another signed version or shared certificate/profile. |
| Same identifier/version collisions | Keep imported and several signed copies with the same Bundle ID/name. Delete each independently and confirm only its exact stored slot changes. Corrupt duplicate UUID ownership must refuse, not delete a sibling. |
| Filtered bulk delete | Select all within a search/scope, then confirm. Only the visible selected records participate; other sections/results remain. Failed deletion retains the selection and reports the failure. |
| Concurrent work | Attempt deletion during signing/installation/export/cleanup ownership. Busy ownership must refuse/defer safely, with no partial erasure. Identity deletion must also respect live signing identity/profile leases. |
| I/O/database failure | Inject a staging move/save/rollback/cleanup failure. Failed commit retains rows and recovery ownership; unrelated pending edits remain pending. A post-commit purge failure retains a recoverable journal. |
| Restart recovery | Interrupt before/after staging, database commit and purge; restart. A surviving committed owner recovers its staged files. Absent owners allow only the journal's exact staged copy to be purged. An unreadable store, corrupt slot/path or replacement collision defers/refuses without destroying unrelated files. |
| Credential migration | Under an instrumented build, fail Keychain read/write and isolated legacy-password persistence. Recoverable plaintext is not cleared on failure, a successful secure copy can be retried, and unrelated edits are not committed. Never include password values in evidence. |

## 6. Real installation and evidence

A complete signing review and verified registered artifact are prerequisites, not
installation proof. Export/package through the existing owners, install the exact
test version using the selected supported transport, inspect device read-back and
launch the installed app. Test an update with the same authorized identity and
inspect expected keychain/capability behavior; then separately test transport
refusal, cancellation, timeout and an unconfirmed submission. Never report a
submitted/unknown install as installed.

Keep a private evidence index with candidate/source/output hashes, device/iOS,
scenario, exact result, redacted diagnostics, screenshots, observed version and
launch outcome. Record elapsed/peak-memory/cancellation measurements only when
actually measured on the device. Mark each row Pass, Fail or Blocked, with a reason.
Only executed positive cases may be called device-verified; all other rows remain
pending. No positive device result is recorded by this document.
