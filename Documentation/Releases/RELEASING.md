# Releasing VexSign

## Release channels

| Channel | Trigger | Tag | GitHub release | Repository listing |
| --- | --- | --- | --- | --- |
| **Stable** | Push a `v<MARKETING_VERSION>` tag, or **Actions → Release** with channel `stable` | `v1.2.1` | Latest release | Updated after publish |
| **Nightly** | Daily schedule at **03:00 UTC**, or a manual dispatch with channel `nightly` | `v1.2.1-nightly.<date>.<run>.<attempt>` | Pre-release | Never updated |

Both channels build the same unsigned IPA, verify the built `CFBundleShortVersionString`
against the tag, and attach `SHA256SUMS` plus a generated changelog. Before publication,
the IPA validator also checks the root bundle ID, expected marketing version, iOS 17.0
minimum, nested app/extension build numbers, and bundle-ID namespace. The IPA filename
includes its app version (`VexSign-<version>.ipa`; nightly suffixes remain in the release
metadata/tag). The IPA still requires a signing identity to install.

Stable versions with reviewed `Documentation/Releases/<version>.md` notes use those
notes and a commit-pinned link to `CHANGELOG.md`, rather than republishing raw
historical commit subjects as feature-readiness claims. `RELEASE.json` records
the notes source. Versions without reviewed notes retain generated history.

## Stable release

1. Bump every `MARKETING_VERSION` setting on main when you want a new version.
2. Push the matching tag, for example `git tag v1.2.1 && git push origin v1.2.1`.
   Tag pushes are the automated stable path. **Actions → Release → Run workflow**
   with channel `stable` is the equivalent manual path for a version that has no
   tag yet.
3. Approve the configured **release** environment. The workflow builds, checks
   the packaged version, publishes the IPA at the exact built commit, then queues
   **Update Repository** for stable releases only.

The current version is **1.2.1**. Published versions and tags cannot be
overwritten. For a test IPA instead, check **build_only**; that run creates an
artifact but no tag or release.

## Nightly pre-release

The **Release** workflow runs every day at 03:00 UTC from the default branch. It
publishes a dated pre-release such as `v1.2.1-nightly.20261107.428.1` and never
moves or reuses that tag, so an installation can be pinned to the exact build it
downloaded. All release runs (stable, nightly and build-only) execute simulator tests before uploading; a
failed nightly can be re-run safely, and the run attempt makes the next tag
unique.

Nightly builds use the **nightly** environment and do **not** update
`app-repo.json`: a pre-release must never become the installation listing's
latest version. Select **nightly** in the manual **Run workflow** form to build
one outside the schedule.

## No certificate-pack service or build-time TLS secret

Releases no longer fetch certificates/private keys or depend on the former
workers.dev certificate server. No `RELEASE_TLS_PACK_URL`, `RELEASE_TLS_SHA256`,
`make deps-pin` or separate TLS bootstrap workflow is required. Old variables
can be removed. No install-server identity is generated on CI or bundled in an IPA.

On the device, VexSign generates a random RSA-2048 root CA and a separate server
key/certificate for `127.0.0.1` and `localhost`, using Apple's Security framework.
The root is valid for ten years; the server certificate is valid for at most 397
days and renews when fewer than seven days remain, **without changing the CA**.
Keys and certificates are persisted as one Keychain record with
`AfterFirstUnlockThisDeviceOnly`, without synchronisation. Only the server key,
chain and hostname are mirrored into a protected, backup-excluded Application
Support cache for NIOSSL. The CA private key is never exported as a file/profile.

### First use / migration

1. Open **Settings → Installation → Server & SSL** to create/check the identity.
2. Export the **Root CA Profile**, install it in system Settings, then enable
   **Full Trust** under **General → About → Certificate Trust Settings**.
3. Use **Fully Local** installation. It uses the device's loopback address, so
   there is no certificate download or DNS dependency.

Previously bundled/downloaded identities are deliberately not reused: their
private keys were shared. Existing users must trust the new device-specific CA
once. The old files may remain in Documents but are no longer read by the local
installer. Existing profiles can be removed manually after active installs finish.

App updates with the same Keychain access identity retain the CA. Restores,
different devices, changed signing/Keychain entitlement, or deleted Keychain data
may require a new CA and trust profile. Locked/unreadable/corrupt Keychain storage
fails closed; it is not treated as permission to silently replace the identity.
An expired CA also fails closed. **Create a New Local CA** explicitly replaces it
only after confirmation, requiring a new trust profile. Finish active installs
before rotation. iOS does not allow the app to silently install or trust a CA.

**Semi Local still uses a remote manifest service.** This change removes the
certificate-pack dependency, not all network services or Apple's signing rules.
Profile trust and `itms-services` behavior require real-device testing; TLS
certificate generation alone does not prove successful installation.

## Repository security setup

Configure these environments under Settings → Environments:

| Environment | Used by | Suggested protection |
| --- | --- | --- |
| `release` | Stable build + publish | Restrict to main and `v*` tags; require reviewers and prevent admin bypass where available. |
| `nightly` | Nightly publish | Restrict to main; no required reviewers so the schedule can run unattended; still restrict who may modify workflows. |
| `build-preview` | `build_only` and nightly build | No write permissions; no deployment approval required. |

YAML names environments but does not configure their rules. Protect the default
branch and release tags with repository rulesets, and restrict who may modify
workflows or trigger deployments. No personal access token is needed.

The workflow retains:

- default-branch ancestry and tag/version checks;
- read-only builds with no persisted Git credentials;
- immutable action SHAs, a run-specific artifact and SHA-256 asset checksums;
- a separate protected write-enabled publisher with no repository checkout;
- refusal to overwrite existing releases or publish a moved tag;
- unique, immutable nightly tags and pre-release marking;
- a separate dispatch-only job to queue the listing updater for stable releases only.

Configured environment approvals may occur for both build and publish. Preview
builds use **build-preview** and do not have release-write permissions. Checksums
are integrity evidence, not independent developer code signatures.

## Tag releases and drafts

Tag pushes remain supported and are the preferred stable path: tag the tested
main commit as `v<MARKETING_VERSION>`, for example `v1.2.1`. Optional prerelease
suffixes (`v1.2.1-beta.1`) mark the GitHub release as a pre-release and are not
synced to the repository listing. Never move a published tag. A tag run can retry
only if no release was created; existing partial/draft releases need manual
inspection.

For a draft, select **draft** in the manual workflow. Drafts do not queue the
repository updater. After publishing a draft through the web UI, check whether
**Update Repository** ran and dispatch it with the tag if needed.

`RELEASE_XCODE` may pin the Xcode version; the manual `xcode` input overrides it.
Build numbers are stamped with the source commit SHA by the existing workflow.

## Validation before shipping

Run `make verify`, manually dispatch **CI → full**, and review the exact commit's
native build/simulator results. Added `DeviceTLSIdentityTests` exercise native
certificate trust, key uniqueness, CA-preserving renewal, serialization and DER
lengths without touching the production Keychain. Device tests must also cover
profile installation/trust, offline Fully Local installation, relaunch/update
persistence, renewal, explicit rotation and locked-device failures.

Use the [real-device acceptance procedure](../QA/DEVICE_TESTING.md) to record the
exact candidate commit, artifact checksum and observed installation results.
Simulator success alone is not device acceptance.

## Release presentation and traceability

Stable and nightly publication both use `Tools/Release/prepare-release-assets.py` after
build and simulator validation. Each attaches:

- the unsigned IPA;
- `CHANGELOG.md`: channel warning, source commit, installation guidance, optional
  reviewed highlights and grouped conventional-commit changes/contributors;
- `RELEASE.json`: source commit, channel/version, run/attempt and IPA checksum;
- the app icon and Home **design illustration**, not a device screenshot;
- `SHA256SUMS` covering the IPA, notes, metadata and both visual assets.

The publisher verifies checksums before publishing. These are integrity checks,
not cryptographic attestations or independent proof of installation. Optional
version-specific highlights belong in `Documentation/Releases/<version>.md`; see the
[authoring guide](README.md). Images in notes are commit-pinned so future
main-branch changes do not alter old release presentations.

## PR-only source updates and GitHub setup

The stable listing updater now opens/refreshes `automation/release-listing`; it
never pushes the listing directly to main. A stable release can be published
before its listing PR is merged, so inspect and merge that PR to update the source.
Nightly releases never create stable-listing updates.

Bot commits on feature/automation branches are normal and precede their PR. To
forbid direct main commits by *any* actor, configure a main ruleset requiring a
PR and checks, without bot/admin bypass. Protect `v*` tags and the release
environment separately. YAML alone cannot enable these protections.

Enable **Allow GitHub Actions to create and approve pull requests** in repository
Actions settings (the workflows only create PRs; they do not approve them).
`GITHUB_TOKEN`-created PRs do not generally trigger downstream PR workflows;
the deterministic maintenance controller explicitly dispatches validators for its
allowlisted bot PRs. Others need a manual validation run. No external App or broad
personal token is required; do not execute untrusted code through `pull_request_target`.

Nightlies are automatic daily at 03:00 UTC (09:00 Dhaka). Stable packaging and
publication are automatic **after a reviewed version is selected** via tag/manual
Release. There is deliberately no daily stable release or automatic version bump:
that would promote unreviewed changes, repeat versions or blur the channel boundary.
The implementation borrows the build/artifact/publication separation seen in
[Lawnicons](https://github.com/LawnchairLauncher/lawnicons/tree/develop/.github/workflows),
not its Android signing setup or secrets. External workflows are references, not
actions dynamically downloaded/executed by this repository.

## Automatic stable dispatch

The Release workflow detects a reviewed, unanimous marketing-version increase
after its full main build/simulator CI passes and dispatches stable packaging.
See [repository operations](../Engineering/MAINTENANCE.md) for the normal workflow.
It never selects a new version itself, publishes an obsolete main candidate or
bypasses the release environment. Set `AUTORELEASE_STABLE=false` to pause it.

### Build numbers and temporary IPAs

Release builds use a deterministic numeric `CFBundleVersion` derived from the
full-history reachable commit count, encoded as four/two/two-digit components.
The exact Git SHA remains in `RELEASE.json` and the release provenance links;
it is not a build number. Stamping failure blocks the build. Before upload or
publication, the staged app and every packaged app/extension must match the
expected build version. Temporary test IPAs are retained for 14 days; diagnostic
logs and publisher staging artifacts retain their shorter 3-day policy.
