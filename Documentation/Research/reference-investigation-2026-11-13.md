# Reference investigation report — 2026-11-13

This is deliverable **B**. It records what was actually inspected, at which immutable revision,
what was learned, how it was used, and why nothing was copied into VexSign. It is an internal
engineering record; no unnecessary upstream branding was added to the app UI, README, commit
messages or release notes. Legally required existing notices in `LICENSE`, `LICENSE_ELLEKIT`,
`Packages/Vendor/README.md` and `Documentation/Security/THIRD_PARTY_ADAPTATIONS.md` remain untouched.

## 1. Method and limits

- Repository metadata and immutable HEAD SHAs were read with
  `gh api repos/{owner}/{repo}` and `gh api repos/{owner}/{repo}/commits/HEAD`.
- Pinned README files were fetched with
  `gh api repos/{owner}/{repo}/contents/README.md?ref=<sha> -H 'Accept: application/vnd.github.raw+json'`.
- Implementation files were fetched with the same `contents/<path>?ref=<sha>` raw endpoint;
  a recursive tree was read with `gh api .../git/trees/<sha>?recursive=1`.
- Existing repository research was used as a starting point:
  `Documentation/Research/upstream-review-inventory.json`,
  `Documentation/Research/signer-file-audit-2026-11.md`,
  `Documentation/Research/public-signer-integration-assessment.md`.
- Outbound access in this sandbox is limited to `github.com`, `codeload.github.com`,
  `api.github.com`, `registry.npmjs.org`, `pypi.org` and `files.pythonhosted.org`.
  `altstoreio/AltServer` API metadata was **unreachable**; no URL/revision was invented for it.
- This is a targeted source investigation, not a whole-repo audit of every listed project.
  Metadata was checked for 17 repositories; seven pinned implementation/README source files and
  one recursive tree were fetched in depth. Remaining upstream implementation files, workflows,
  tests, dependency manifests and licences beyond the listed items were not read in this pass.

## 2. Repository metadata at pinned HEAD

| Repository | Default branch | Licence (API) | HEAD SHA inspected | Pushed at |
| --- | --- | --- | --- | --- |
| `https://github.com/NuzProjects/Feather` | `main` | GPL-3.0 | `fafed68b45a6a69ef88fb4e0c58168a0be38f631` | `2026-11-13T21:32:18Z` |
| `https://github.com/seomin0610/Feather` | `main` | GPL-3.0 | `8c5e9bbdfddae480fa2cbcd089158684d7594779` | `2026-10-25T14:23:46Z` |
| `https://github.com/mirazbakis/Odysseus` | `master` | GPL-3.0 | `2664dadedf9aca36fda0925a8aada92e2c79323f` | `2026-10-07T17:42:31Z` |
| `https://github.com/korboybeats/KorSign` | `main` | GPL-3.0 | `f20892f43177476ef769b2ac76fc038f87d963ec` | `2026-10-13T21:39:16Z` |
| `https://github.com/gliddd4/MySignReincarnated` | `main` | GPL-3.0 | `c21554d69de8821d6fd3a323371badbeb7d764e0` | `2026-09-13T05:59:46Z` |
| `https://github.com/8yy/BatSign` | `main` | GPL-3.0 | `d60dbee57228e74d4502c24ff825f154fa33c45b` | `2026-10-10T12:08:51Z` |
| `https://github.com/Mesutcydev/ForgeSign-iOS` | `main` | none detected | `275e33a390b47647426dacbf1b6360b4afd70f0f` | `2026-11-13T22:07:18Z` |
| `https://github.com/FrizzleM/FreeSign` | `main` | GPL-3.0 | `3bcd14b3a7737626550753c728ef1ed2676da00a` | `2026-06-18T12:52:40Z` |
| `https://github.com/pwnapplehat/iPASide` | `main` | MIT | `6b721393964fd654a8984c22e00ead068e1e3109` | `2026-11-12T10:12:42Z` |
| `https://github.com/FrizzleM/SideInstaller` | `main` | NOASSERTION (custom) | `82452dfd2a575b5a031145de2b22b98d4b7b3a76` | `2026-11-13T11:26:48Z` |
| `https://github.com/Dadoum/Sideloader` | `main` | GPL-3.0 | `631abccace368ececbbd4ed82c35a245834e3af0` | `2026-11-06T13:57:37Z` |
| `https://github.com/SideStore/SideStore` | `develop` | AGPL-3.0 | `4f3d18d98c5fbee72c80f787ceb2e8e09ded60a6` | `2026-11-07T04:28:46Z` |
| `https://github.com/LiveContainer/LiveContainer` | `main` | AGPL-3.0 | `9d6ea09b05afa2c8fc537c372795a294db631311` | `2026-11-13T13:34:58Z` |
| `https://github.com/altstoreio/AltStore` | `marketplace` | AGPL-3.0 | `56854e66fef2eac32dad88dcbad1dc131d430e60` | `2026-10-21T16:13:02Z` |
| `https://github.com/zhlynn/zsign` | `master` | MIT | `9299685bab7ef99827e06e5dfda93af747386590` | `2026-10-20T05:45:58Z` |
| `https://github.com/libimobiledevice/libimobiledevice` | `master` | LGPL-2.1 | `fa0f79190142bc309307967c058f89c1b36eb6b8` | `2026-06-10T07:52:18Z` |
| `https://github.com/opa334/TrollStore` | `main` | NOASSERTION | `88424f683b2a08f34a3f88985f790f97d84ce1df` | `2026-04-01T09:43:17Z` |

`https://github.com/altstoreio/AltServer` returned `ERROR/UNREACHABLE` from the GitHub API in
this sandbox; it is deliberately excluded from any adaptation claim.

## 3. Pinned documents fetched

| Repository | Pinned `README.md` | Lines | Relevant discovery |
| --- | --- | --- | --- |
| zsign | `https://github.com/zhlynn/zsign/blob/9299685bab7ef99827e06e5dfda93af747386590/README.md` | 291 | MIT, cross-platform iOS 12+ `codesign` alternative; persistent `.zsign_cache`, multi-profile signing, dylib injection/removal, bundle editing, ad-hoc signing, certificate/OCSP checks, metadata extraction, cleanup. |
| iPASide | `https://github.com/pwnapplehat/iPASide/blob/6b721393964fd654a8984c22e00ead068e1e3109/README.md` | 310 | MIT; Windows app using Apple ID; **requires Apple Devices/iTunes for USB**, sign-in/2FA, plug in/unlock/trust device, then Settings trust for developer profile. Reinforces that computer-free install is not universal. |
| Dadoum/Sideloader | `https://github.com/Dadoum/Sideloader/blob/631abccace368ececbbd4ed82c35a245834e3af0/README.md` | 203 | GPL-3.0 desktop-side sideloading route; no source copied. |
| SideInstaller | `https://github.com/FrizzleM/SideInstaller/blob/82452dfd2a575b5a031145de2b22b98d4b7b3a76/README.md` | 218 | Warns malicious forks can insert credential stealers. Requires iOS 27+ plus `siboot`, Wi-Fi and Developer Mode for computer-free install; iOS 26.4–26.7 and 17.4–26.3 need a PC-created pairing file; below 17.4 unsupported. Link schemes: `sideinstaller://install?url=`, `sideinstaller://pairingFile?data=`, `sideinstaller://certificate?data=<base64 PKCS#12>&password=`. |
| LiveContainer | `https://github.com/LiveContainer/LiveContainer/blob/9d6ea09b05afa2c8fc537c372795a294db631311/README.md` | 211 | AGPL-3.0 guest-runtime limitations; VexSign already gates `EmbeddedContainerRuntime`. |
| TrollStore | `https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/README.md` | 126 | NOASSERTION; relies on platform-specific exploitation, not a general install route. Not integrated. |

A recursive tree for SideInstaller at
`82452dfd2a575b5a031145de2b22b98d4b7b3a76` listed 439 paths, including `.github/workflows/`
and `ios-app/*.swift` (`AccountStore.swift`, `AnisetteServers.swift`, `CertManager.swift`,
`DeviceConnection.swift`, `DownloadsManager.swift`, `LogRedactor.swift`, etc.). Only the files
in the next section were fetched.

## 4. Implementation source inspected in depth

All files below are from `https://github.com/FrizzleM/SideInstaller` at commit
`82452dfd2a575b5a031145de2b22b98d4b7b3a76`.

| Path | Size | Discovery | Usefulness / adaptation | VexSign files changed | Tests |
| --- | --- | --- | --- | --- | --- |
| `LICENSE.md` | 2,918 B | Custom licence: personal/educational/non-commercial use, study and modification allowed; **commercial use and redistribution of official releases prohibited without written authorisation**; projects that *incorporate* the Software must credit "SideInstaller by FrizzleM" and link the official repository. | Determined that no source may be copied into VexSign. VexSign remains an independent scratch project; no attribution was added to UI/docs because no source was incorporated. | none | licence review recorded here |
| `ios-app/DeepLink.swift` | 7,370 B | `decodeBase64` normalises base64url `-`/`_`, form-decoded spaces, whitespace and missing padding; `LinkedCertificate.isPlausibleArchive` bounds a PKCS#12 to 64 KiB and checks DER `0x30`; pairing files bounded to 1 MiB; every parsed link requires user confirmation. | Inspired an **independent** standard-base64 normaliser with a decoded-size bound. VexSign uses `URLComponents`, which does not turn `+` into a space, so literal spaces are removed rather than converted to `+` (avoids corrupting valid base64). No upstream expression, type or comment was copied. | `Packages/NimbleKit/Sources/NimbleExtensions/FileManager/FileManager+shortcuts.swift` | `App/Tests/VexSignTests/DeepLinkBase64StagingTests.swift`, `Tools/Development/test_integration_contracts.py` |
| `ios-app/LogRedactor.swift` | 12,206 B | Redacts keys for pairing secrets, serials, cellular/network identities, Apple account/anisette state, device names, UDIDs and Apple IDs; retains model/iOS/build/states/team ID and value *shape*; handles plist, JSON, Rust `{:#?}`, idevice and Swift `Key = value` printed forms. | Identified key/identifier classes missing from VexSign's narrow `LogRedaction`. VexSign's rules were **independently written** as `NSRegularExpression` patterns with a different marker, different templates and a smaller, explicit key list. No upstream regex, marker or code was copied. | `App/iOS/VexSign/Utilities/Logging/LogRedaction.swift` | `App/Tests/VexSignTests/LogRedactionTests.swift`, `Tools/Development/test_integration_contracts.py` |
| `ios-tests/LogRedactorTests.swift` | 10,833 B | Uses `Swift Testing` suites, synthetic values only, and asserts idempotency/non-overfire boundaries. | Confirmed the need for both positive redaction and "ordinary line stays readable" tests; VexSign uses its existing XCTest style instead. | `App/Tests/VexSignTests/LogRedactorTests.swift` | same |
| `ios-app/LogStore.swift` | 3,503 B | Every line is redacted before display, copy or stdout mirror; bounded 2,000-line buffer; off-main queue. | Confirms VexSign's existing `FileLogger`/`LogRedaction` architecture is the right boundary. No change. | none | none |
| `ios-app/DownloadsManager.swift` | 3,612 B | Distinguishes downloaded vs imported IPA, stable path identity, single-flight deletion, `hasLoaded` vs empty, refresh after delete. | Compared with VexSign's `DownloadManager`/library lifecycle; no missing behaviour proven, so no change. | none | none |
| `ios-app/PairingManager.swift` | 7,650 B | Pairing/session orchestration source was fetched but not used for an adaptation decision in this pass. | Recorded for future device-pairing comparison; VexSign's `PairingBridge`/`HeartbeatManager` gates remain. | none | none |
| `NOTES.md` | 97,675 B (size only) | Only size metadata was read; contents were not fetched. | No conclusion drawn. | none | none |

## 5. Area-by-area comparison outcome

| Area | Upstream evidence | VexSign outcome |
| --- | --- | --- |
| Signing engine | zsign MIT README; VexSign already vendors `Packages/Vendor/Zsign`. | Existing pipeline preserved; `SigningService`/`SigningHandler` output verification and `SignatureVerifier` gates unchanged. |
| IPA/archive safety | SideInstaller deep-link bounds; VexSign `Tools/Development/test_archive_extraction_policy.py`, `ArchiveHandler`. | Added a decoded-size bound and base64 normalization to the deep-link staging helper, not a second archive engine. |
| Certificate/profile import | SideInstaller certificate callback bounds; VexSign `CertificateManagementService`, `IdentityVault`. | Deep-link base64 staging hardened; password/P12 validation unchanged. |
| Free Apple account | SideStore AGPL-3.0, SideInstaller custom licence, SideInstaller README prerequisites. | `nativeAppleAccountSigning: .notIntegrated` preserved; no unlimited provisioning or computer-free claim added. |
| Installation/bootstrap | SideInstaller iOS 27+/PC-pairing prerequisite, iPASide USB/computer requirement, TrollStore platform exploit. | `Documentation/Distribution/bootstrap.md` remains honest; `ManifestService` now refuses unverified external manifests. |
| Guest container | LiveContainer AGPL-3.0 README. | `EmbeddedContainerRuntime.isAvailable` gate preserved; no AGPL code copied. |
| Repository/download integrity | SideInstaller `DownloadsManager.swift`. | No change; existing `DownloadIntegrity`/`LibraryIntegrityAudit` retained. |
| Task/storage/backup | VexSign `TaskHistoryJournal`, `UnifiedTaskCenter`, `BackupManager` plus existing policy tests. | No blind resume or silent deletion introduced; no change. |
| Cloud signing | VexSign `Services/CloudSigning/cloud-signing/src/signer.ts`, `worker.ts`, `CloudSigningClient.swift`. | `privateKeyUploadDisabled` and strict `signatureVerified: true` retained; no infrastructure deployed. |
| Security/privacy | SideInstaller `LogRedactor.swift`, `LogStore.swift`. | VexSign log redaction extended independently; no secrets exposed. |
| CI/build | Current-HEAD CI annotations; `Tools/CI/test_workflow_policy.py`. | Two Swift 6 errors fixed and guarded; no CI check weakened. |

## 6. Safety and licence conclusions

- **No source code was copied** from SideInstaller, SideStore, LiveContainer, AltStore, TrollStore,
  Feather, KorSign, iPASide, zsign or any other listed project in this pass.
- GPL-3.0 / AGPL-3.0 / LGPL-2.1 / NOASSERTION / no-licence projects were treated as
  study-only. VexSign's existing vendored MIT zsign and existing third-party notices were left
  intact.
- SideInstaller's custom licence would require attribution and prohibits commercial use if its
  source were incorporated. Because VexSign implemented independent standard behaviours and
  copied no expression, no new public-facing attribution or "inspiration" clue was added.
- No new dependency, binary, certificate, private key, token or credential was introduced.
- The two adapted behaviours are covered by local Python contract tests and new Swift XCTest
  cases; the XCTest cases require a macOS CI run (user-controlled commit/push) to execute.
