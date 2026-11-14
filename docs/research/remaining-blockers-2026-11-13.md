# Remaining blockers — 2026-11-13

Deliverable **F**. These are the real gaps after the 2026-11-13 implementation pass. Each has an
exact dependency and a concrete next action. No blocker is hidden behind a roadmap claim, and no
`Build-verified` / `Device-verified` result is fabricated.

## 1. Current-branch CI build and simulator tests

| Field | Value |
| --- | --- |
| Status | `Blocked (Build-verified)` |
| Evidence | Baseline `ci.yml` run `43513058621` on `c67fab28` failed `build` + `tests` with two Swift 6 diagnostics. The two diagnostics are fixed and guarded by `tools/test_swift6_build_regressions.py`. At the user's request the branch was pushed and PR #235 was opened; GitHub Actions checks started, but no green build/test result had been observed when this blocker list was published. |
| Exact dependency | macOS-15 runner with Xcode selected by `.github/scripts/select_xcode.sh`; Swift package cache; `code-signing` disabled generic iOS build; simulator runtime; a completed green PR-triggered `ci.yml` run. |
| Next action | Watch PR #235 checks, record the `ci.yml` run URL, confirm `quick`, `build`, `tests`, `concurrency` all succeed, and attach the `xcodebuild` / `xcresult` artifacts. Do not promote any `Blocked (Build-verified)` row until then. |

## 2. Physical iPhone acceptance

| Field | Value |
| --- | --- |
| Status | `Blocked (Device-verified)` |
| Evidence | No device was available; `docs/QA_DEVICE_ACCEPTANCE.md` explicitly says nothing was run. |
| Exact dependency | A legitimately signed installable VexSign build, one real iPhone, one paid P12/profile with the device UDID, one owned test IPA, optional pairing file + loopback VPN, and evidence storage. |
| Next action | Execute [device-acceptance-guide-2026-11-13.md](device-acceptance-guide-2026-11-13.md) end to end; produce the evidence manifest with SHA-256, screenshots, redacted logs and exact error texts. Leave unmeasured fields null. |

## 3. Native Apple-account signing promotion

| Field | Value |
| --- | --- |
| Status | `Gated` / `Blocked (Build-verified, Device-verified)` |
| Evidence | `SigningMethodCapabilities.swift` keeps `nativeAppleAccountSigning: .notIntegrated`; `tools/check-native-handoff.py` requires production `.appleCMS()`; `tools/native-promotion-evidence.py` rejects fixture/simulator/self-signed markers. |
| Exact dependency | Genuine Apple-issued provisioning profile CMS obtained from the Apple Developer Portal, pinned Apple roots, negative/tamper CMS fixtures, full signing + device evidence ladder, production verifier wiring, and real-device install/launch confirmation. |
| Next action | Obtain the genuine CMS fixture and complete the evidence ladder in `docs/NATIVE_SIGNING_HANDOFF.md`; only then change the capability report and the production verifier selection. Do not bypass Apple code signing or claim free-account provisioning. |

## 4. Computer-free bootstrap / public install route

| Field | Value |
| --- | --- |
| Status | `Not implemented` |
| Evidence | `docs/distribution/bootstrap.md`: release workflow publishes an **unsigned** IPA; no TestFlight upload, Ad Hoc portal, Enterprise/MDM enrollment, eligible marketplace distribution, stable HTTPS portal, or production release trust key exists. |
| Exact dependency | App Store Connect app record/enrollment, distribution signing credentials, protected GitHub environments, a signed archive/export per channel, HTTPS artifact/manifest hosting with correct MIME types, a mobile-first portal, a protected Ed25519 release-signing key with the public key embedded in the app, and device-specific eligibility validation. |
| Next action | Choose one legitimate channel, configure credentials outside CI/test artifacts, implement and test the signed export + portal + trust envelope, then validate from physical Safari. Keep the honest "no self-install from unsigned IPA" wording until then. |

## 5. Cloud signing infrastructure

| Field | Value |
| --- | --- |
| Status | `Gated` |
| Evidence | `CloudSigningClient.privateKeyUploadDisabled`; `cloud-signing/src/signer.ts` requires strict `signatureVerified: true`; `worker.ts` verifies digests, clears `sealed_password`, validates ZIP output and HMAC-signs allowlisted webhooks. No production service, secrets, queue or object store was deployed. |
| Exact dependency | Real isolated signer infrastructure, secret management, authenticated job queue, S3-compatible storage with integrity checks, HMAC webhook secrets, rate limits, audit logging, and a safety review of private-key handling. |
| Next action | Deploy and exercise the existing service against real infrastructure with negative tests; keep the client gate until an end-to-end signed artifact is verified. Never enable private-key upload by default. |

## 6. Unattended free-account profile renewal

| Field | Value |
| --- | --- |
| Status | `Not implemented` |
| Evidence | `docs/FEATURE_MATRIX.md` and `SigningMethod.swift`: `UnattendedSigningGrant` covers background signing with an existing certificate, not account/profile renewal. |
| Exact dependency | Security design review for account operations, explicit user consent model, credential/session storage policy, revocation, and a renewal state machine that survives restart without blind resume. |
| Next action | Write the design, add state/consent/negative tests, then implement behind an explicit grant. Do not reuse the existing signing grant. |

## 7. Multi-device pairing and exactly-once crash-safe import

| Field | Value |
| --- | --- |
| Status | `Blocked` |
| Evidence | `UnifiedTaskCenter` / `TaskHistoryJournal` provide conservative recovery, not exactly-once crash-safe import/database commit; pairing transport is single-session. |
| Exact dependency | Transactional journal + Core Data commit protocol, crash-injection test matrix, and a multi-session pairing transport design. |
| Next action | Run the force-quit fault-injection matrix in the acceptance guide, record the exact crash windows, then implement only the proven missing transaction. Do not claim exactly-once behavior. |

## 8. Release authenticity / trust key

| Field | Value |
| --- | --- |
| Status | `Blocked` |
| Evidence | `docs/distribution/bootstrap.md`: release verifier has no production trust key; existing GitHub checksums are not an authenticity guarantee. |
| Exact dependency | Protected Ed25519 signing key, public key embedded in the app, signed release envelopes, key rotation/compromise procedure, and verifier tests with tamper cases. |
| Next action | Create the key outside the repository, publish the public half, implement envelope verification, and add negative tests. Never commit private key material. |

## 9. Complete upstream source comparison

| Field | Value |
| --- | --- |
| Status | `Blocked` |
| Evidence | Deliverable B: metadata for 17 repos, seven pinned source/README files and one tree were inspected; many implementation files, workflows, tests, dependency manifests and licences remain unread. `altstoreio/AltServer` API was unreachable. |
| Exact dependency | Network access to the pinned upstream repositories/files, time to read each area, and licence review for GPL/AGPL/NOASSERTION/no-licence projects. |
| Next action | Continue from `docs/research/upstream-review-inventory.json`; fetch the remaining pinned implementation paths, record exact URLs/SHAs/paths/discoveries, and only adapt independently with tests. Do not copy unlicensed or AGPL/GPL source without the required notices. |

## 10. User-controlled Git/release actions

| Field | Value |
| --- | --- |
| Status | `Blocked` by explicit user instruction |
| Evidence | No commit, push, PR, merge, release, tag, visibility change, secret change or deployment was executed. |
| Exact dependency | The user's decision to commit/push/merge/release using the [proposed Git changes](proposed-git-changes-2026-11-13.md). |
| Next action | Review the working tree, then apply the suggested commit sequence and PR title. The agent must not execute these actions. |
