# End-to-end feature status

Every claim below is tracked as a full pipeline — **setting → persisted value
→ real consumer** — instead of a blanket "supported". The same registry is
visible in-app under *Settings → About → Feature Status* and enforced by
`StabilityAndArchitectureTests.testFeatureStatusRegistryCoversCriticalPipeline`.

Legend:

- **Implemented** — the chain is wired in code and covered by unit tests
  where the host allows it (settings → persistence → consumer).
- **Needs device** — wired end-to-end, but the last mile (actually
  signing/installing on real hardware) requires a physical-device pass that
  CI cannot provide.

| Feature | Setting | Persisted as | Consumer | Status |
| --- | --- | --- | --- | --- |
| Forced signing | Advanced Signing → Force Sign All | `Options` (OptionsManager) | `SigningHandler` → `ZsignEngine` → zsign | Implemented |
| SDK spoofing / Mach-O changes | Signing Options → SDK & Mach-O | `Options` (OptionsManager) | `SigningHandler.modify()` | Implemented |
| Auto-sign on download | Automation → Sign after download | `VexSign.autoSign…` keys | `DownloadManager` → `AutoSignManager.sign()` | Implemented |
| Download integrity | The source's own `size` (a hash when a source publishes one) | Nothing persisted — the expectation lives on the `Download` for the length of that download | `DownloadManager.handlePackageFile` → `DownloadIntegrity` → import gate (and the one deliberate "Import Anyway") | Needs device |
| Signed repositories | A `vexsign` member in the source's `source.json` | `VexSign.sourceProvenance` (badge cache; the signature is checked on every refresh) | `SourceProvenanceVerifier` → `SourceFeedLoader` refuses a refresh whose signature does not verify · repository row badge | Implemented |
| Install-method preflight | Settings → Installation (method picker) | `VexSign.installationMethod` · server certificate · pairing file | `InstallPreflight` → the "Install methods" rows in `InstallationView` | Implemented |
| Anti-revoke endpoint | Settings → Installation → Anti-Revoke (endpoint field, off by default) | `VexSign.novaDNSRulesURL` + `VexSign.useNovaDNSDynamic` | `NovaDNSDynamic.actionURL` → the PPQ request · `AppInstaller` logs each rewrite | Implemented |
| Tweak injection defaults | Tweaks → ⋯ → Inject by Default | `ManagedTweak.injectByDefault` in `library.json` | `TweakManager` → sign-time injection | Implemented |
| OCSP revocation evidence | — (no setting yet; nothing calls it) | Nothing persisted | `OCSPValidator` (request/parse/verify/policy). **Not wired**: no request is built and no UI shows a verdict | Needs device |
| Profile compatibility | Signing → Start Signing (preflight) · certificate picker badge | Nothing persisted — computed from the decoded profile, the p12 and the signing options | `PreflightChecks` → `ProfileCompatibility` → `PreflightIssue` / `CertificatesCellView` | Implemented |
| Extension coverage audit | Signing → Remove App Extensions (stripped extensions are never requirements) | Nothing persisted — each nested bundle's `Info.plist` and `embedded.mobileprovision` are read per run | `NestedBundleAudit` → `SigningHandler` (signing log) · `PreflightChecks` / `SigningView` (coverage target) | Implemented |
| Post-sign verification | Signing log (every sign) · Install Without Signing (blocks) | `SignatureVerifier.Report` on `SigningHandler.verification`, not persisted | `SigningHandler.modify` → `SignatureVerifier` → `DirectInstaller` | Implemented |
| Signing cancellation & stage progress | Signing sheet → Stop Signing (while signing) · Library → Batch Sign → Cancel | Nothing persisted — `SigningService` state is per-run | `SigningService` → `SigningHandler.onStage` → `SigningLog` / Live Activity / `UnifiedTaskCenter` | Implemented |
| Install confirmation | — (every install and self-update) | Nothing persisted — the verdict is per-install | `AppInstaller` / `SelfUpdateManager` → `InstallConfirmation` → `InstalledAppProbe` (`LSApplicationProxy`) | Needs device |
| Library install state & signer identity | — (every library row and info sheet) | Nothing persisted — the device answer and the bundle's CMS are read on demand, cached 30 s | `LibraryStatusStore` → `LibraryCellView` / `LibraryInfoView` · `PreflightChecks.signerIdentity` → `CertificateIdentity` → `BundleSignature` | Needs device |
| Community certificate catalogue | Settings → Certificates → + → Community Certificates (Unofficial) | `UserDefaults` `nexCerts.acknowledgedHost` — the acknowledged host, not a flag | `NexCerts.fetchCatalog`/`importCertificate` via `CommunityCertificatesView` | Implemented |
| Encrypted backup | Settings → Backup & Restore → Create Backup → Password | `VEXBK2` container: content key wrapped by PBKDF2 password key or Keychain `backup.deviceKey` | `BackupCrypto.seal/unseal` → `BackupManager.makeBackup/open` | Implemented |
| Certificate revocation check | Settings → Certificates → Certificate Health → Validate with System OCSP | `VexSign.certificate.revocationSnapshots` (status, detail, date only) | `CertificateInspector` (OCSP) → `CertificateStatusManager` → badge | Implemented |
| Web Manager access control | Settings → Web Manager → Require Password / Allow This Network | `VexSign.webManager.{auth,user,bindMode,allowUnauthenticatedLAN}` + Keychain password | `WebManagerAccessPolicy` → bind host + `WebManagerSensitiveAccessMiddleware` | Implemented |
| Web Manager certificate export | Settings → Web Manager → Allow Certificate Download | `VexSign.webManager.certificateExport` | `WebManagerServer.allowsCertificateExport` → `/api/certs/:uuid/download` (403 when off) | Implemented |
| Web Manager API token | Settings → Web Manager → API Token | Keychain `webManager.apiToken` (legacy `VexSign.apiToken` migrated) | `WebManagerAuthMiddleware` (alternative credential) + sensitive-route gate | Implemented |
| Compatibility opt-out clearing | Signing Options → Compatibility | `Options` (OptionsManager) | `SigningHandler.modify()` on update | Implemented |
| Per-app certificate selection | App context → Signing certificate | per-app options / `PerAppUpdateRules.pinnedCertificateUUID` | `FR.signPackageFile(certificate:)` | Implemented |
| Quick Sign | Home → Quick Sign | — (immediate action) | `FR.handlePackageFile` → `SigningView` | Implemented |
| Re-sign / re-install | Library → app → Re-sign | — (library action) | `FR.signPackageFile` → `InstallQueue` | Needs device |
| Asset / file modifications | Signing customization, IPA Explorer | per-app options + IPA Explorer edits | `SigningHandler` / file replacement | Implemented |
| Dynamic Island download controls | Downloads settings | Live Activity state | `DownloadProgressAttributes` + app-group commands | Needs device |
| Strict app hiding | Settings → Security → Hidden Apps Vault | `AppLockManager` sets | Library/Home filters | Implemented |
| Six-tab navigation structure | Settings → Tab Bar (launch tab only) | `TabBarPreferences` (primary tabs immutable) | `TabbarView` | Implemented |
| Appearance (theme/font/animations) | Settings → Appearance | `AppearanceStore` (4 keys) | App root environment, `Theme`, button styles | Implemented |
| Offline repository catalog | automatic (last-known-good) | `SourceSnapshots/` | `SourcesViewModel` prefill + stale marking | Implemented |
| Unified task pipeline | Downloads → Task Center | `UnifiedTaskHistory.json` (outcomes only) | DownloadManager mirror, `FR.signPackageFile`, `InstallQueue` | Implemented |
| Per-app update rules | Updates → context menu → Update Rules | `VexSign.perAppUpdateRules` | `AppUpdateChecker.precomputeAllUpdates` | Implemented |
| Source health monitoring | App Store → Repositories → Source Health | `SourcePreferences` health records | `SourcesViewModel` refresh outcomes | Implemented |
| HTTPS-only repository transport | Settings → Security (HTTP opt-in) | `VexSign.sources.allowInsecureHTTP` | `SourceURLPolicy` (add + refresh) | Implemented |
| Encrypted backup & restore | Settings → Backup | `.vexbackup` (AES-GCM, PBKDF2 200k) | `BackupManager` + `BackupCrypto` | Implemented |
| First-run setup wizard | automatic on first launch | `VexSign.onboardingCompleted` | Certificate/source/IPA/import-method pages | Implemented |

## What "Needs device" means in practice

`Re-sign/reinstall` and the `Dynamic Island` controls depend on hardware and
OS behavior that a simulator cannot fully exercise (pairing, Live Activities
on notch hardware, installd timing). Both flows are wired through the same
`UnifiedTaskCenter` pipeline as the tested flows, so a device pass only needs
to confirm the last hop.

## Release-side status

- The six primary tabs (Files → Library → Home → App Store → Downloads →
  Settings) are **immutable by construction** — enforced by
  `TabBarPreferences` and covered by
  `MissingFeatureTests.testPrimaryTabsAreImmutableAndAlwaysVisible`.
- Synthetic compatibility tags (`v0.0.1` … `v0.0.18`, `v1.0.0`) run
  **validation-only** in the Release workflow and never publish; real
  releases still require `tag == MARKETING_VERSION` before and after the
  build. See `docs/RELEASING.md`.
