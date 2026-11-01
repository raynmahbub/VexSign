# Releasing VexSign

## Automated release with a one-time trust setup

After this workflow update is merged, publishing is **Actions → Release → select
main → Run workflow**, leaving **build_only unchecked**. The current version is
`v1.1.0`. Check **build_only** for an unpublished test IPA instead.

### One-time setup (entirely in the web UI)

1. Under **Settings → Environments**, create **release**. Restrict deployment
   branches/tags to the default branch and your release-tag pattern (`v*`).
   Configure required reviewers and prevent self-review/admin bypass where your
   plan supports it. Environment protection is NOT created by workflow YAML:
   merely naming an environment does not secure it. Without reviewer support,
   rely on reviewed committed pins and protected default-branch/tag rules instead.
2. Run **Actions → Pin release TLS identity** from the reviewed default branch.
   Review the source, common name, certificate expiry and public digest. Verify
   the source/identity with the provider via an independently trusted channel;
   fetching the same pack twice proves consistency, not authenticity.
3. Set **RELEASE_TLS_SHA256** (the 64 lowercase hexadecimal digest characters)
   under **Settings → Environments → release → Environment variables**.
   Alternatively, commit the reviewed public pin through a PR. If both are set,
   they must agree. The workflow never silently learns or replaces a trust anchor.
4. Protect the default branch and release tags with repository rulesets; limit
   who can change workflows/environment variables or trigger deployments. This
   change does not edit those settings. No personal access token is required.

### Every release afterwards

Run **Release** on `main`. The workflow automatically:

- restricts publication to commits in default-branch history;
- enforces the approved digest, HTTPS transport, certificate chain/hostname,
  expiry and key matching; unavailable/changed/invalid identities fail closed;
- builds and verifies the app version with a read-only token;
- transfers an immutable run-specific artifact to a separate protected publisher
  that does not check out or execute repository build scripts;
- verifies SHA-256 asset checksums and refuses to overwrite an existing release;
- publishes the IPA, public TLS pin and `SHA256SUMS` at the exact built commit;
- queues the repository-listing updater for non-draft releases using a separate
  dispatch-only job (Actions write, no repository checkout).

Release workflow actions are pinned to full commit SHAs. Both build and publisher
use the **release** environment, so configured approvals may be requested at each
job. Preview builds use **build-preview** and have no release-write permission.
Checksums detect changed assets; they are not an independent code-signing identity.
The IPA intentionally contains the local install-server identity as documented
below; no raw pack or standalone private key is uploaded as an artifact.

**A missing or changed approved pin blocks publication.** This is deliberate:
secure automation cannot decide to trust a new key on its own. For a legitimate
rotation, repeat the review helper and update the approved variable/committed pin.
No local tools or manual tag creation are needed for routine releases, but builds
and provider availability must still succeed. Existing published versions cannot
be overwritten: bump `MARKETING_VERSION` for a new release.

## Publish a release (tag push)

1. **Bump the version.** Set `MARKETING_VERSION` for all targets - Xcode →
   VexSign target → *General* → *Version*, or from the repo root:

   ```sh
   agvtool new-marketing-version 1.2.0
   ```

   Commit it (`chore(release): bump version to 1.2.0`) and land it on `main`
   through a normal PR. Manually run CI with full validation on the release branch and review the
   result for the exact commit before tagging; PR validation is not automatic.

2. **Tag that commit and push the tag.**

   ```sh
   git checkout main && git pull
   git tag -a v1.2.0 -m "VexSign v1.2.0"
   git push origin v1.2.0
   ```

3. **Watch the run** under *Actions → Release*. On success it has:
   - a GitHub release `VexSign v1.2.0` for the tag, with `VexSign.ipa` attached
     and release notes generated from the commits since the previous release;
   - the same IPA attached to the run as an artifact.

4. **Check source-listing sync.** The successful non-draft publisher explicitly
   dispatches **Update Repository** for the released tag. Check that separate run
   for completion. If it fails, rerun it with the tag; publication already happened
   and should not be repeated. Pre-releases are synced too.

### Tag rules

- The tag is **`v` + `MARKETING_VERSION`**, exactly: `1.2.0` → `v1.2.0`,
  `1.2` → `v1.2`. The workflow refuses a tag that doesn't match the project
  (before building) and a build whose `CFBundleShortVersionString` doesn't
  match the tag (after building), so a stale version can never ship under a
  new tag.
- **Pre-releases** append a suffix: `v1.2.0-beta.1`, `v1.2-rc1`. The release
  is marked as a pre-release; the app still reports `1.2.0` (Apple version
  strings can't carry the suffix). Release notes for a pre-release cover
  everything since the last tag of any kind; notes for a stable release skip
  pre-release tags, so `v1.2.0` lists everything since `v1.1.0`.
- **Never move a tag that has been published.** If a release must change, cut
  a new patch version. If the tag run *failed* (nothing was published), fixing
  and re-tagging is fine: `git tag -f v1.2.0 && git push -f origin v1.2.0`.
- The **build number** (`CFBundleVersion`) is the full commit SHA, stamped by
  CI, so any installed build can be traced back to its source.

### Reproducibility knobs

- Tag runs use the newest Xcode on the runner image. To pin the toolchain,
  set a repository variable **`RELEASE_XCODE`** (e.g. `26.3`) under
  *Settings → Secrets and variables → Actions → Variables*. A manual run's
  `xcode` input overrides it for that run only.
- Preview the notes CI will generate:

  ```sh
  VERSION=1.2.0 tools/generate-changelog.sh
  ```

## Local install server TLS identity (R12)

Every IPA carries a certificate and private key in `deps/`. The app's *Fully Local* install
mode serves `itms-services` over HTTPS from the device with that pair, so it is shipped
material, not a build detail:

| | Where it comes from | Used for |
|---|---|---|
| **Development identity** | `make deps` → `Scripts/local-tls/make-dev-identity.sh` (openssl, offline, random key, deterministic names) | building and testing on your own device |
| **Release identity** | `make deps-release` → the published pack, verified against `Scripts/local-tls/pinned-pack.sha256` | every IPA that is handed to anyone else |

**The trust assumption.** The device has to trust the issuing Root CA before `itms-services`
accepts an HTTPS manifest: *Settings → Installation → Server & SSL → Export Root CA Profile*,
then full trust under *Settings → General → About → Certificate Trust Settings*. The
development identity is therefore self-contained but needs that one manual step; the release
identity is the one users of the published IPA are expected to trust.

**Why the build pins a digest.** The pack is fetched over HTTPS from a single mutable
endpoint. Without a pin, whoever controls that endpoint controls the private key inside every
IPA built by this repository — key material that can impersonate the install server to a
device that trusted its CA. `make deps-release` computes the digest over the three identity
files (`Scripts/local-tls/pack_digest.py`, rule documented in the script) and refuses to build
unless it matches the pin. The alternative the roadmap also allowed — a self-signed identity
for releases — was rejected: it would rotate the CA on every build and silently break the
trust profile of every existing user.

### GitHub Actions-only setup (no local tools required)

1. Land `.github/workflows/pin-release-tls.yml` on the default branch so its
   manual dispatch button is available.
2. Open **Actions → Pin release TLS identity → Run workflow** and choose the
   branch whose release configuration you intend to use.
3. Wait for success. This runs `make deps-pin`, then `make deps-release` to
   verify a fresh download against the generated pin. If the endpoint is down,
   malformed, expired or inconsistent, fix the endpoint rather than bypassing checks.
4. Download the **release-tls-pin-<run-id>** artifact and unzip it. It contains
   only `pinned-pack.sha256`, never the certificate pack or private key.
5. Review the source, common name, expiry in the run log, and digest. Confirm
   the source/identity is the one you intend to ship: consistency is not proof
   of source trust. Using the repository web editor, replace
   `Scripts/local-tls/pinned-pack.sha256` with that file and commit through a PR.
6. Merge the reviewed pin and validate the release commit before publishing.
   The bootstrap workflow itself does not commit, tag or release anything.

The release workflow still downloads and verifies the approved identity. If the
provider rotates it later, repeat this review; never blindly update a pin just
because a release failed. Build-only runs use a development identity and do not
prove that the release pin is ready.

**Local runbook**

```sh
# First time, and after a deliberate rotation:
make deps-pin          # fetch, print cn + digest, rewrite Scripts/local-tls/pinned-pack.sha256
git diff               # this diff IS the review: a changed digest = a changed key
git commit -am "chore(tls): pin the release install-server identity"

# Every release build (the Release workflow does this before `make`):
make deps-release      # fetch + verify + install into deps/
```

`make deps-release` fails without a digest. Release can populate the build's pin
from the approved `RELEASE_TLS_SHA256` variable before invoking it; it never
bootstraps trust from an unapproved download.

**What is *not* pinned, and why.** The in-app "Update SSL Certificates" action fetches the same
pack on demand, because the certificate is short-lived and users need a working identity
between releases. A digest baked into an old build would reject every legitimate refresh, so the
runtime path validates instead of pinning: the chain must parse, the key must be present, the
hostname must be usable, the leaf must not be expired — and nothing is written unless all of
that passes. The action is explicitly confirmed by the user, and the app always shows which
identity is live (source, mode, hostname, expiry) in *Server & SSL*.

---

## Test a change without publishing (`build_only`)

1. *Actions → Release → Run workflow*.
2. Pick the branch (or tag) to build. Check **`build_only`** (it is unchecked by default).
   Optionally set `xcode` to try a specific toolchain.
3. When the run finishes, the IPA is under *Artifacts* on the run page
   (`VexSign-<version>-<sha>`, kept for 14 days). The run summary links to it.

Nothing else happens: no release, no tag, no `app-repo.json` change. Pull
requests do not trigger this automatically; dispatch the build explicitly.

## Synthetic compatibility tags (validation-only runs)

The repository history carries **synthetic milestone tags** — `v0.0.1` through
`v0.0.18`, `v1.0.0` — annotated like:

```
VexSign v0.0.18 FlareStore parity milestone (synthetic tag)
```

They mark parity milestones and intentionally do **not** match
`MARKETING_VERSION` (currently `1.1.0`). Pushing or re-pushing one therefore
must not fail the version checks and must never publish a release. The
workflow detects the phrase *synthetic tag* in the tag annotation and:

- runs the **full build + packaging + validation** for the tagged commit;
- attaches the IPA to the run as an **artifact** (same as `build_only`);
- publishes **nothing** and does not touch `app-repo.json`;
- reports itself as a **compatibility milestone** in the run summary.

Real releases are unaffected: a tag whose annotation does not say *synthetic
tag* still has to match `MARKETING_VERSION` exactly, before *and* after the
build.

## Manual publication details

With `build_only` unchecked, the default branch run publishes
`v<MARKETING_VERSION>` at the exact commit that was built. Check `draft` to stage
an unpublished draft instead; draft runs do not queue the repository updater.

- Branch publication refuses an already-existing tag.
- A tag run may retry a build that failed before release creation, but it cannot
  overwrite any existing release, including a partial/draft release. Inspect a
  partial release manually before deciding how to recover.
- A new public release requires a new version. Never move a published tag.
- Tag targets are checked again before publication. Repository tag rulesets are
  still required to prevent external tag mutations/races.

## When something goes wrong

| Symptom | What it means | Fix |
| --- | --- | --- |
| `v1.2.0 does not match the project's MARKETING_VERSION (1.1.0)` | The tag was pushed before the version bump landed. | Bump the version, commit, move the tag onto that commit (`git tag -f v1.2.0 && git push -f origin v1.2.0`). |
| `The built app reports CFBundleShortVersionString 1.1.0, but v1.2.0 promises 1.2.0` | Same thing, caught after the build (targets disagreed on the version, so the pre-build check was skipped). | Set the same `MARKETING_VERSION` on every target and re-tag. |
| `v1.2.0 already exists on origin; refusing to overwrite` | A manual publish targeted a version that is already released. | Bump `MARKETING_VERSION` for a new release. Existing releases cannot be overwritten by this workflow. |
| Tag push did nothing | The tag doesn't match `v<major>.<minor>[.<patch>][-<suffix>]`. | Delete it and push a correctly named tag. |
| Build failed on a tag push | A build or validation failure. | Inspect whether a release exists first. If none was created, fix on `main` and retry using an unpublished tag; never move a published tag. |
| Release exists but `app-repo.json` didn't update | `Update Repository` failed or ran before the assets were visible. | *Actions → Update Repository → Run workflow* with `tag` = `v1.2.0`. |
