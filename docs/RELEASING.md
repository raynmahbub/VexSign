# Releasing VexSign

## One-workflow release

After this update is merged into the default branch:

1. Open **Actions → Release → Run workflow**.
2. Select **main**. Leave **build_only unchecked** to publish (the default).
3. Approve any configured release-environment deployments. The workflow builds,
   checks the version, publishes the IPA at the exact built commit, then queues
   **Update Repository**. Check that separate run for completion.

The current version is **1.1.0**. For subsequent releases, first update all
`MARKETING_VERSION` settings and land the changes on main. Published versions
cannot be overwritten. For a test IPA instead, check **build_only**; that run
creates an artifact but no tag or release. The IPA still requires signing to install.

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

Configure the **release** environment under Settings → Environments. Restrict
branches/tags to main and your release-tag pattern, and enable required reviewers,
prevent self-review/admin bypass where your plan supports these controls. YAML
names an environment but does not configure its protection rules. Protect the
default branch and release tags with repository rulesets, and restrict who may
modify workflows or trigger deployments. No personal access token is needed.

The workflow retains:

- default-branch ancestry and tag/version checks;
- read-only builds with no persisted Git credentials;
- immutable action SHAs, a run-specific artifact and SHA-256 asset checksums;
- a separate protected write-enabled publisher with no repository checkout;
- refusal to overwrite existing releases or publish a moved tag;
- a separate dispatch-only job to queue the listing updater for non-draft releases.

Configured environment approvals may occur for both build and publish. Preview
builds use **build-preview** and do not have release-write permissions. Checksums
are integrity evidence, not independent developer code signatures.

## Tag releases and drafts

Tag pushes remain supported: tag the tested main commit as `v<MARKETING_VERSION>`,
for example `v1.1.0`. Optional prerelease suffixes (`v1.1.0-beta.1`) do not change
the numeric bundle version. Never move a published tag. A tag run can retry only
if no release was created; existing partial/draft releases need manual inspection.

For a draft, select **draft** in the manual workflow. Drafts do not queue the
repository updater. After publishing a draft through the web UI, check whether
**Update Repository** ran and dispatch it with the tag if needed.

Synthetic annotated tags whose messages contain `synthetic tag` remain
validation-only compatibility milestones, never publications. Their intentional
version mismatch is tolerated; real release versions must match the built bundle.

`RELEASE_XCODE` may pin the Xcode version; the manual `xcode` input overrides it.
Build numbers are stamped with the source commit SHA by the existing workflow.

## Validation before shipping

Run `make verify`, manually dispatch **CI → full**, and review the exact commit's
native build/simulator results. Added `DeviceTLSIdentityTests` exercise native
certificate trust, key uniqueness, CA-preserving renewal, serialization and DER
lengths without touching the production Keychain. Device tests must also cover
profile installation/trust, offline Fully Local installation, relaunch/update
persistence, renewal, explicit rotation and locked-device failures.
