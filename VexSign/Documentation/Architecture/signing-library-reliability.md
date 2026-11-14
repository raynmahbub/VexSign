# Signing and library reliability follow-up

## Status and scope

The signing/library implementation is recorded in
`bf063e778cc2bdf3bdbcd5a84646cc6b95b6d285`, based on
`8daf7e7e577cd05597a29d69952ea2c80e31e3ee` on `arena/bf87c593-vexsign`.
Publication and integration of current `main` were subsequently authorized, with
existing published commit history retained. The integration source is
`725a2769be00ad60542102f472bbb879c8136f86`; it does not merge the pull request,
release or deploy anything. Historical CI in
[the migration record](feature-layout-migration.md) does not validate this candidate.
Record new CI outcomes against the exact integrated PR head, not an older artifact.

The existing application, signing engine, library repositories, task history,
packaging and installation owners remain in place. The separate experimental
native Apple-account implementation is **not** promoted into production.

The implementation and portable regressions are present. **Apple compilation,
Objective-C++/Security execution, XCTest, hosted SwiftUI layout, gestures and
physical-device acceptance of this working tree remain outstanding.** Do not
replace those requirements with a simulator build, an unsigned IPA or synthetic
CMS success. The detailed checklist is
[signing/library device acceptance](../DeviceTesting/SIGNING_LIBRARY_ACCEPTANCE.md).

## Findings and the attached signing-screen issue

A selected certificate row is neither proof of access to its private key nor
proof that its profile covers an application's identifier. The earlier screen
could show a completed identity row, a failed setup row and an enabled Start
Signing action because those surfaces consumed different evidence. The old
Start action opened review; its enabled appearance did not itself prove that
native signing had begun. An execution row saying Not run is consistent with
an admission failure.

The source correction makes the checklist, action panel and review consume one
`SigningReadiness` value:

- Checking cannot approve. Ready requires a completed inspection; Warning still
  requires review and any explicit nonmandatory-risk confirmation.
- An unauthenticated/expired/incompatible identity or profile, uncovered retained
  component, unsupported binary, missing device authorization, unauthorized
  entitlement or failed workspace inspection blocks approval.
- Start Signing is disabled while checking or blocked. Review Signing Issues
  remains available, with component identifiers, the profile's actual App ID,
  the failed requirement and import guidance.
- Options, certificate/inventory projections, foreground entry and Check Again
  invalidate the visible result. Cancelled or late inspections cannot publish an
  old approval. Approval is bound to the reviewed setup and component plan.
- Original application and extension identifiers are preserved by default. No
  profile-derived identifier suggestion is supplied by `SigningView`. Explicit
  existing customization features remain, but are not a provisioning workaround;
  their resulting identifiers must independently pass every mandatory check.

A profile for another explicit App ID **must continue to fail**. Import compatible
Apple-issued profiles and their matching complete identities instead of changing
identifiers or bypassing checks. Certificates → Get Info → Extension Profiles is
retained for importing additional component profiles.

The screenshot does not establish which revision was installed, which file was
actually imported, or the complete failing IPA/profile contents. The installed
failure has **not** been reproduced or repaired on a device here. The known
source-level UI disagreement and fail-closed execution path are addressed; the
real profile mismatch remains an actionable refusal, not a claimed signing
success. An unreadable framework is also not evidence that it is resource-only.

## Existing device flow and execution ownership

Paths below are relative to `VexSign/App/iOS/VexSign/` unless stated otherwise.

| Phase | Authoritative owner and flow |
| --- | --- |
| Download/import | `Infrastructure/Downloads/DownloadManager+PackageImport.swift` hands off to `Infrastructure/Archives/IPA/PackageImportService.swift`; existing archive validation, extraction and imported-artifact registration remain. A downloaded source archive and a stored imported bundle are distinct artifacts. |
| Library | `Presentation/Features/Library/Views/LibraryView.swift` and `LibraryCellView.swift` consume immutable workspace records through the existing library model/use case/repository. Store-bound identities distinguish downloaded/imported and signed slots, including copies with the same Bundle ID. |
| Certificate/profile storage | `Infrastructure/Identity/SigningIdentityStore.swift` snapshots existing `CertificatePair` rows, primary files and `ExtensionProfiles/`; `Infrastructure/Identity/Certificates/ProvisioningProfileParser.swift` admits authenticated metadata. The original protected certificate-directory getter is unchanged. |
| Readiness | `Presentation/Features/Signing/Views/SigningView.swift`, `SigningChecklist.swift` and `SigningPreflightReviewView.swift` share `Domain/Results/SigningReadiness.swift`. `Infrastructure/Signing/Execution/LibrarySigningAdapter.swift` owns the platform inspection behind the existing port. |
| Resolution | `Infrastructure/Signing/Planning/SigningResolutionSession.swift` builds targets from `SigningPlan.swift`, reads profiles and identities, and calls `Domain/Services/CompatibleIdentityResolver.swift`. It binds a reviewed plan without granting trust to UI values. |
| Run admission | `Infrastructure/Signing/Execution/PackageSigningCoordinator.swift` re-resolves the actual main identity before `SigningService.swift` creates a run. Batch, re-sign, automation and sheet requests continue through this owner. |
| Copy/customization | `SigningPipeline.swift` → `SigningHandler.swift` copies into the existing owned working directory. Source bytes and original required capabilities are captured before plist/binary customization. `Infrastructure/Archives/IPA/InfoPlistPlan.swift` remains the existing explicit customization owner. |
| Native signing | `ZsignHandler.swift` acquires `SigningExecutionGate.swift`, takes a leased inventory, re-authenticates current inputs, and calls `Infrastructure/Signing/Engines/Zsign/ZsignAdapter.swift` / `ZsignEngine.swift`. The one existing vendored engine remains under `VexSign/Packages/Vendor/Zsign/`. |
| Verification/registration | `Infrastructure/Signing/Verification/SignatureVerifier.swift` and `SignatureVerifier+Seals.swift` verify the fresh output against exact per-component assets. `SigningHandler` requires the complete verified verdict before moving/registering it through existing signed storage. |
| Packaging/export/install | Existing `AppArchiver`, export and installation owners consume the registered artifact. No bytes inside the sealed app are intentionally customized after verification. Export, installation submission, device read-back and successful launch remain separate outcomes. |
| Deletion/recovery | `Infrastructure/Persistence/Database/Storage+Shared.swift` and `StagedAppDeletion.swift` quarantine the exact stored slot and use database commit as the deletion boundary. Existing launch recovery and cleanup ownership are retained. Ordinary library Delete never invokes an uninstall. |

## Provisioning and identity admission

`ProvisioningProfileParser.parse` has no XML-substring or raw-plist trust fallback.
The existing Objective-C++ bridge now verifies the fully consumed CMS envelope,
content and signed attributes, one signer, and supported SHA-256/384/512 digest
algorithms. Public Security APIs evaluate the actual Apple provisioning signer
chain offline at the supplied time and check reviewed Apple roots. A descriptive
metadata seam in tests is explicitly **not** authenticated inventory.

Metadata validation requires consistent UUID, name, dates, App ID prefix, single
team, platform list, developer-certificate list, devices and typed entitlements.
Certificate DER and calendar dates must be fully consumed/valid. App ID prefix
and Team ID are separate concepts; a legacy prefix need not equal the team.
Malformed/truncated, untrusted, expired or unsupported inputs are rejected, not
accepted after a failed CMS check. File reads are bounded and links refused.

Identity proof imports the actual PKCS#12 through Security, selects a single leaf
identity and performs a random RSA/ECDSA signing/verification challenge. It never
exports a private key or substitutes a certificate listed by a profile for the
actual PKCS#12 leaf. Missing certificate, absent key and inaccessible key/password
are distinct diagnostic states. The selected leaf's fingerprint, team and validity
must agree with the authenticated profile's authorized certificates.

The inventory is bounded to 512 rows/profiles and 4,096 identity/profile pairs;
invalid UUIDs never reach path/Keychain access, and failed discovery discards that
row's partial file inventory. An unavailable Keychain remains a nil password with
fixed actionable diagnostics, never an empty-password fallback. The final run
checks the unchanged saved password and revocation/status evidence while holding
identity/profile leases. Those leases coordinate app-owned mutations, not arbitrary
external filesystem writes.

Password migration now validates stored UTF-8 before clearing recoverable legacy
text. Reads/writes also require a valid UUID and an attached, nondeleted row before
accessing Keychain; a deleted identity cannot recreate its password. A successful
secure write followed by a failed isolated plaintext-field save can retry from the
secure copy without replacing it. Reading a password no longer saves unrelated
pending view-context edits. Per-call injected operations cover read, write and
persistence failures without a global Keychain override or real secrets.

**Known support limit:** the current provisioning trust policy pins reviewed signer
names, roots, chain shape and algorithms; the native CMS writer supports a bounded
issuer set. A newly issued legitimate Apple profile/issuer may be reported unsupported.
No positive production Apple-profile/private-key/Security bridge/device result was
obtained here. Do not broaden trust or infer installation support to hide that gap.

## Component resolution, entitlements and signing order

- Every imported profile is considered with every imported identity, not just the
  profile stored beside the selected row. Exact valid App IDs rank before valid
  wildcards. Main-app candidates are tried with same-team nested resolution so a
  locally preferred main profile cannot lock extensions onto an unusable team.
- Automatic resolution is the default; disabling it restricts the selected identity.
  Per-component manual preferences use public certificate fingerprints/profile UUIDs,
  never paths/passwords. An unavailable or incompatible explicit preference blocks
  instead of silently substituting another asset. Final execution revalidates it.
- The recursive typed manifest includes main/nested apps, extensions, Watch code,
  executable frameworks, loadable bundles and dylibs. Incomplete discovery, links,
  collisions, duplicate identifiers, unsupported executable kinds and unowned Mach-O
  code block signing. A resource-only bundle needs positive `BNDL`/no-executable/
  clean-descendant evidence; an unreadable or malformed framework is not skipped.
- Native signing uses explicit per-component profile/identity/entitlement inputs,
  nearest profile-bound inheritance for libraries, loose libraries before enclosing
  bundles, deepest nested bundles before parents and the main app last. The profile
  is embedded before its enclosing seal is generated.
- Required entitlements are captured before transformations. Typed authorization
  preserves Boolean-versus-number semantics, validates every requested capability,
  and allows only documented wildcard shapes. Identity entitlements describe the
  new authorized signer; required capabilities are not silently reduced. A profile
  is a capability ceiling, not a template to copy wholesale.
- Unsupported DER entitlement/value shapes and library entitlements that this engine
  would discard are refused explicitly. The verifier currently supports the reviewed
  CodeDirectory/old plist-DER subset; it does not claim every modern signature format.
- Compatibility removal is off by default. Only positively recognized optional,
  top-level extensions without retained references/nested apps qualify. Unknown
  references, bounded-scan failures and required/Watch components prevent removal.
  The exact functionality-loss list requires explicit review; saved settings or
  automation alone cannot approve a newly different removal list. The retained tree
  is re-resolved and audited before signing.
- A framed source digest binds paths, empty directories, lengths and streamed bytes.
  The copy must match review before customization. Approval also binds typed
  capabilities, selected assets, PKCS#12 digests, removals and hashed target-device
  evidence. Protected temporary input copies are cleaned with their working owner.

## Fresh verification and native parser safeguards

Fresh output is checked independently for every retained image: CodeDirectory
bounds, page hashes, special slots, detached CMS, actual SignerInfo leaf, alternate
SHA-256-directory binding, team/identity, XML/DER entitlement agreement, embedded
profile digest/authorization, nested code and resource seals. Tamper fixtures cover
executable pages, requirements, entitlements, resources, profiles and signer changes.
`Report.requireVerified()` prevents an incomplete import-style inspection from
registering fresh device-signing output. Preflight overrides cannot waive this gate.

Native Mach-O bounds, FAT table byte orders/ranges, command padding, allocation/file
ownership, DER encoding, CMS attribute handling, error propagation and signing order
have behavioral regressions. The vendor plist reader now bounds input to 64 MiB,
depth to 64 and expanded nodes to 200,000; checks binary trailers/tables/references;
uses unaligned-safe byte reads; and rejects unsupported/invalid Unicode, scalar,
length, cycle and duplicate-key cases. XML preserves declared numeric types and
significant string whitespace, decodes predefined/numeric entities, rejects integer
overflow/nonfinite reals and internal entity DTDs, and validates UTC dates without
calendar normalization or host-timezone dependence. Binary dates use the correct
2001-01-01 UTC epoch in both reader and writer. A failed public read clears its
partial tree. Bundle-node and resource-envelope generation explicitly check parse
success and required string fields instead of consuming partial/coerced metadata.
The native regression refuses malformed, trailing, missing and incorrectly typed
main metadata before executable mutation/sealing, with a valid synthetic positive
control. Independent Python plistlib XML/binary encoding/decoding checks catch
shared reader/writer mistakes.

Both vendor `common/json.cpp` and `json.h` were normalized from CRLF to LF while
editing. Review functional changes with `git diff --ignore-space-at-eol --` for
those paths; the raw line-count churn is not an engine replacement.

## Compact Delete and transactional storage

The same trailing action is used by list/card/icon layouts. One store-bound revealed
row ID belongs to `LibraryView`. Left reveals and right closes; full swipes only
reveal, never delete. Other row taps close an open action without also navigating.
The content reserves bounded trailing space instead of moving its leading icon off
screen. The compact red trash/caption background does not set the row's height.
Dynamic Type width is clamped to 72–136 points (82 default), with a 44-point trash
control, named accessibility actions and Reduce Motion/appearance animation support.
Actual hit-testing/VoiceOver/screenshot acceptance remains a device requirement.

The existing confirmation states that deletion removes only the stored library
copy. `Storage.deleteApps` resolves all exact committed records, refuses duplicate
or foreign ownership, leases their slots, writes a durable journal, stages files,
and saves deletions in an isolated context. Save/move failures preserve rows and
rollback ownership; post-commit cleanup failures retain a recoverable journal.
Recovery checks the persistent store and allowed original/slot paths before any
mutation, defers when the store is unreadable and refuses replacement collisions.
Cleanup cannot race active signing/deletion ownership. Bulk selection is scoped to
visible filtered records and is retained when the transaction fails. Neither app
deletion nor its recovery deletes shared certificate/profile storage or an installed
application.

## Validation record for this candidate

| Check | Observed result / limit |
| --- | --- |
| Native C++ regressions | **36 passed, 0 failed**, normally and with AddressSanitizer + UndefinedBehaviorSanitizer, including the final bundle-metadata checks; independent plistlib interoperability passed in both runs. Generated non-runnable images, ephemeral non-Apple keys/PKCS#12 and public-only CMS fixture; no Apple trust/device acceptance. |
| Portable repository validation | Final `make verify` passed, including the 75-case experimental-native preparation suite. These are portable/source/fixture groups, not an Apple build or execution of production signing through Security. |
| Identity/readiness/output wiring | **14 portable source-policy cases passed**; these pin wiring, not Security/Core Data runtime behavior. |
| Preservation-auditor fixtures | **27 passed**. Public Security-framework linkage and the exact incoming main Cloud lock are narrowly audited exceptions. Negative fixtures reject altered locks, changed original hashes and unrelated removed URLs. |
| Original-file preservation | **1,375 originals accounted for**: 895 byte-identical, 480 rewritten text; 1,322 relocations and 216 added files. All 35 original binaries and ten license texts are preserved. 26/28 protected inputs remain exact; the two exceptions are public Security-framework linkage and the byte-exact incoming main Cloud lock. Original recorded hashes are unchanged. |
| Swift grammar | **85 changed Swift files, 0 grammar findings**; full comparison **959 original / 1,158 current files**, the same **25 / 25 known findings and no new signatures**, in `feature-migration-preservation.json`. Neither check is Swift type checking. |
| Localization | **736 files / 3,708 distinct literals / 4,189 catalogue keys**, no missing localized-call keys; existing translations are not pruned. |
| Public certificate fixture | The calendar-mutation anchor is present in the public DER. This check is not execution of `ProvisioningAdmissionTests`. |
| Main service integration | Cloud TypeScript build, **14 tests**, contract generation with no OpenAPI drift, and WebManager **216 tests** passed after the incoming dependency updates. One upstream Starlette/httpx deprecation warning; no skips. No deployment acceptance is implied. |
| Apple build / Objective-C++ / XCTest | **Not run locally for this candidate**: no Swift/Xcode/Apple SDK. Existing Actions build/test jobs are retained and the Linux quick job now runs native ASan/UBSan. New remote outcomes must be checked for the exact integrated PR head; historical successes are not candidate validation. |
| Hosted UI / iPhone installation | **Not run**. Two hosted layout methods and additional resolver/admission/seal/source/readiness/lease/inventory/migration/deletion XCTest regressions await Apple execution. No positive authenticated end-to-end signing/install result is claimed. |

Reproduce native checks with a C++17 compiler and matching OpenSSL 3 development
headers/libraries already installed (the driver never downloads them):

```sh
make verify
make test-signing-core
VEXSIGN_NATIVE_SANITIZERS=1 make test-signing-core
# If headers need an explicit location:
OPENSSL_INCLUDE_DIR=/path/to/openssl/include make test-signing-core
```

The upstream native input lock and revision remain byte-identical. The isolated
preparation still verifies the original upstream manifest; the app-local public
Security-linkage review is separate in
`VexSign/Packages/NativeSigning/app-vendored-zsign-review.json`. No permissive
baseline regeneration, target deletion, license replacement or production promotion
is used to obtain a green check. The service dependency updates below come from
main integration, not native signing or a regenerated lock.

## Main integration and conflict resolution

GitHub reported PR #243 as conflicting with main despite a clean local merge
preview. Main is integrated without rewriting the published branch commits and
without choosing the old dependency versions merely to avoid a content change.
The three incoming service files keep their migrated owners:

| Incoming owner at `725a276` | Retained destination and evidence |
| --- | --- |
| `Services/API/server/requirements.txt` | `VexSign/Services/WebManager/Configuration/requirements.txt`; byte-identical to main, including FastAPI `0.162.4`. |
| `Services/CloudSigning/cloud-signing/package-lock.json` | `VexSign/Services/Cloud/package-lock.json`; byte-identical to main, SHA-256 `e6931af4c320d691770bbe7258a8167e696a372bef11d54eaa4054e49899f47a`. |
| `Services/CloudSigning/cloud-signing/package.json` | `VexSign/Services/Cloud/package.json`; every non-script field matches main, including AWS SDK `^3.1166.0` and BullMQ `^6.7.4`. The already-migrated command paths remain unchanged. |

The preservation auditor still compares every recorded original hash with the
original Git blob. Its second protected-input exception binds the exact original
and incoming Cloud lock digests and source revision. Only dependency URLs actually
superseded by that exact lock pair are accounted for separately; there is no blanket
registry/domain exclusion. Tampering, a different lock, altered original bytes or
an unrelated deleted URL still fails the audit. The main requirements and lock
are also independently compared byte-for-byte with their real source Git blobs.

## Changed-file inventory

The following appendix is a candidate path inventory relative to the repository
root, compared with the follow-up base `8daf7e7`. It is not a replacement for reviewing
`git diff`, the newly added files or the original-hash preservation report.

```text
.github/workflows/ci.yml
Makefile
VexSign/App/iOS/VexSign/Domain/Entities/SigningEngineRequest.swift
VexSign/App/iOS/VexSign/Domain/Entities/SigningResolution.swift
VexSign/App/iOS/VexSign/Domain/Policies/SigningIdentityPolicyValues.swift
VexSign/App/iOS/VexSign/Domain/Protocols/LibrarySigningProviding.swift
VexSign/App/iOS/VexSign/Domain/Results/BundleExecutableAuditValues.swift
VexSign/App/iOS/VexSign/Domain/Results/SigningCapabilityValues.swift
VexSign/App/iOS/VexSign/Domain/Results/SigningReadiness.swift
VexSign/App/iOS/VexSign/Domain/Results/SigningResolutionReview.swift
VexSign/App/iOS/VexSign/Domain/Services/CompatibleIdentityResolver.swift
VexSign/App/iOS/VexSign/Domain/Services/ProfileApplicationIdentifierMatcher.swift
VexSign/App/iOS/VexSign/Domain/Services/ProfileEntitlementAuthorization.swift
VexSign/App/iOS/VexSign/Domain/ValueObjects/SigningOptions.swift
VexSign/App/iOS/VexSign/Infrastructure/Archives/IPA/MachOEntitlements.swift
VexSign/App/iOS/VexSign/Infrastructure/Identity/CertificateRemoval.swift
VexSign/App/iOS/VexSign/Infrastructure/Identity/CertificateWorkspaceAdapter.swift
VexSign/App/iOS/VexSign/Infrastructure/Identity/Certificates/CertificateReader.swift
VexSign/App/iOS/VexSign/Infrastructure/Identity/Certificates/ProvisioningProfileParser.swift
VexSign/App/iOS/VexSign/Infrastructure/Identity/SigningIdentityStore.swift
VexSign/App/iOS/VexSign/Infrastructure/Persistence/Database/StagedAppDeletion.swift
VexSign/App/iOS/VexSign/Infrastructure/Persistence/Database/Storage+Certificate.swift
VexSign/App/iOS/VexSign/Infrastructure/Persistence/Database/Storage+Shared.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Engines/Zsign/ZsignEngine.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Execution/LibrarySigningAdapter.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Execution/PackageSigningCoordinator.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Execution/SigningExecutionGate.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Execution/SigningHandler.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Execution/SigningPipeline.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Execution/SigningRequest.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Execution/SigningService.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Execution/ZsignHandler.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Planning/OptionalExtensionPolicy.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Planning/PreflightChecks.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Planning/SigningInputValidation.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Planning/SigningPlan.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Planning/SigningResolutionSession.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/BundleExecutableAudit.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/BundleSignature.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/DER.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/ExecutablePreflight.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/NestedBundleAudit.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/ProfileCompatibility.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/SignatureVerifier+Seals.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/SignatureVerifier.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/SigningCapability.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/SigningIdentity.swift
VexSign/App/iOS/VexSign/Infrastructure/Signing/Verification/SigningIdentityPolicy.swift
VexSign/App/iOS/VexSign/Platform/Apple/Localization/BundleExecutableAuditLocalization.swift
VexSign/App/iOS/VexSign/Presentation/Features/Certificates/Views/CertificatesView.swift
VexSign/App/iOS/VexSign/Presentation/Features/Certificates/Views/Info/CertificatesInfoView.swift
VexSign/App/iOS/VexSign/Presentation/Features/Library/Views/LibraryCellView.swift
VexSign/App/iOS/VexSign/Presentation/Features/Library/Views/LibraryGridSwipeDelete.swift
VexSign/App/iOS/VexSign/Presentation/Features/Library/Views/LibraryView+BatchActions.swift
VexSign/App/iOS/VexSign/Presentation/Features/Library/Views/LibraryView.swift
VexSign/App/iOS/VexSign/Presentation/Features/Signing/ViewModels/SigningWorkspaceModel.swift
VexSign/App/iOS/VexSign/Presentation/Features/Signing/Views/SigningChecklist.swift
VexSign/App/iOS/VexSign/Presentation/Features/Signing/Views/SigningPreflightReviewView.swift
VexSign/App/iOS/VexSign/Presentation/Features/Signing/Views/SigningView.swift
VexSign/App/iOS/VexSign/Resources/Localization/Localizable.xcstrings
VexSign/App/iOS/VexSign/Security/Certificates/CertificateSecrets.swift
VexSign/Documentation/Architecture/ARCHITECTURE.md
VexSign/Documentation/Architecture/feature-layout-migration-map.json
VexSign/Documentation/Architecture/feature-layout-migration.md
VexSign/Documentation/Architecture/feature-migration-preservation.json
VexSign/Documentation/Architecture/signing-library-reliability.md
VexSign/Documentation/Decisions/History/signing-code-audit.md
VexSign/Documentation/Decisions/History/signing-compatibility-and-removal-ux.md
VexSign/Documentation/DeviceTesting/DEVICE_TESTING.md
VexSign/Documentation/DeviceTesting/SIGNING_LIBRARY_ACCEPTANCE.md
VexSign/Packages/NativeSigning/PythonTests/test_prepare_smoke.py
VexSign/Packages/NativeSigning/app-vendored-zsign-review.json
VexSign/Packages/NativeSigning/prepare_smoke.py
VexSign/Packages/Vendor/Zsign/Package.swift
VexSign/Packages/Vendor/Zsign/Sources/zsign.swift
VexSign/Packages/Vendor/Zsign/src/archo.cpp
VexSign/Packages/Vendor/Zsign/src/archo.h
VexSign/Packages/Vendor/Zsign/src/bundle.cpp
VexSign/Packages/Vendor/Zsign/src/bundle.h
VexSign/Packages/Vendor/Zsign/src/common/base64.cpp
VexSign/Packages/Vendor/Zsign/src/common/fs.cpp
VexSign/Packages/Vendor/Zsign/src/common/json.cpp
VexSign/Packages/Vendor/Zsign/src/common/json.h
VexSign/Packages/Vendor/Zsign/src/macho.cpp
VexSign/Packages/Vendor/Zsign/src/openssl.cpp
VexSign/Packages/Vendor/Zsign/src/openssl.h
VexSign/Packages/Vendor/Zsign/src/openssl_tools.hpp
VexSign/Packages/Vendor/Zsign/src/openssl_tools.mm
VexSign/Packages/Vendor/Zsign/src/signing.cpp
VexSign/Packages/Vendor/Zsign/src/zsign.hpp
VexSign/Packages/Vendor/Zsign/src/zsign.mm
VexSign/Services/Cloud/package-lock.json
VexSign/Services/Cloud/package.json
VexSign/Services/WebManager/Configuration/requirements.txt
VexSign/Tests/SecurityTests/CredentialRedaction/CredentialMigrationDiagnosticsTests.swift
VexSign/Tests/Support/Fixtures/CodeSignatureCMSFixture.json
VexSign/Tests/Support/SigningRegressionFixture.swift
VexSign/Tests/UnitTests/Application/MissingFeatureTests.swift
VexSign/Tests/UnitTests/Application/SignatureVerifierTests.swift
VexSign/Tests/UnitTests/Application/StagedAppDeletionTests.swift
VexSign/Tests/UnitTests/Persistence/LibraryGridSwipePolicyTests.swift
VexSign/Tests/UnitTests/Persistence/LibrarySwipeLayoutTests.swift
VexSign/Tests/UnitTests/Signing/BundleExecutableAuditTests.swift
VexSign/Tests/UnitTests/Signing/BundleSignatureTests.swift
VexSign/Tests/UnitTests/Signing/ComponentSigningResolverTests.swift
VexSign/Tests/UnitTests/Signing/ExecutablePreflightTests.swift
VexSign/Tests/UnitTests/Signing/NestedBundleAuditTests.swift
VexSign/Tests/UnitTests/Signing/ProfileApplicationIdentifierMatcherTests.swift
VexSign/Tests/UnitTests/Signing/ProfileCompatibilityTests.swift
VexSign/Tests/UnitTests/Signing/ProvisioningAdmissionTests.swift
VexSign/Tests/UnitTests/Signing/SignatureSealTests.swift
VexSign/Tests/UnitTests/Signing/SigningCapabilityTests.swift
VexSign/Tests/UnitTests/Signing/SigningIdentityLeaseTests.swift
VexSign/Tests/UnitTests/Signing/SigningIdentityPolicyTests.swift
VexSign/Tests/UnitTests/Signing/SigningInventoryTests.swift
VexSign/Tests/UnitTests/Signing/SigningReadinessTests.swift
VexSign/Tests/UnitTests/Signing/SigningSourceAndRemovalTests.swift
VexSign/Tests/UnitTests/Signing/ZsignEngineTests.swift
VexSign/Tests/WorkflowTests/InstallationWorkflow/ImportAndInstallationTests.swift
VexSign/Tests/WorkflowTests/SigningWorkflow/FullSignPipelineIntegrationTests.swift
VexSign/Tools/Validation/architecture-rules/audit_feature_preservation.py
VexSign/Tools/Validation/architecture-rules/test_feature_preservation.py
VexSign/Tools/Validation/architecture-rules/test_feature_workspace_boundaries.py
VexSign/Tools/Validation/repository-validation/test_workflow_trace_policy.py
VexSign/Tools/Validation/security-validation/native/SigningCoreRegressionTests.cpp
VexSign/Tools/Validation/security-validation/test_native_signing_core.py
VexSign/Tools/Validation/security-validation/test_signing_identity_policy.py
```
