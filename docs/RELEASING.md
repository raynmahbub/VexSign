# Releasing VexSign

Two rules cover almost everything:

1. **Real releases are tag pushes.** Push `vX.Y.Z` and CI builds, verifies and
   publishes it. Reproducible (the tag pins the commit and the version) and
   automatic (no inputs to remember, and `app-repo.json` is synced afterwards).
2. **Testing is `build_only = true`.** Run the Release workflow manually from any
   branch, leave `build_only` ticked (the default), and download the IPA from
   the run page. Nothing is published, no tag is created.

Both run the same [`Release` workflow](../.github/workflows/release.yml); they
just stop at different points.

## Publish a release (tag push)

1. **Bump the version.** Set `MARKETING_VERSION` for all targets - Xcode →
   VexSign target → *General* → *Version*, or from the repo root:

   ```sh
   agvtool new-marketing-version 1.2.0
   ```

   Commit it (`chore(release): bump version to 1.2.0`) and land it on `main`
   through a normal PR. The PR build proves the release commit compiles before
   it is tagged.

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

4. **The source updates itself.** Publishing the release triggers the
   [`Update Repository`](../.github/workflows/update_repo.yml) workflow, which
   rewrites `app-repo.json` (version, download URL, size, notes, news card) and
   commits it to `main`. Pre-releases are synced too - they are "published"
   releases as far as GitHub is concerned.

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

**Runbook**

```sh
# First time, and after a deliberate rotation:
make deps-pin          # fetch, print cn + digest, rewrite Scripts/local-tls/pinned-pack.sha256
git diff               # this diff IS the review: a changed digest = a changed key
git commit -am "chore(tls): pin the release install-server identity"

# Every release build (the Release workflow does this before `make`):
make deps-release      # fetch + verify + install into deps/
```

Until a digest is pinned, `make deps-release` fails on purpose, and so does the Release
workflow. That is the intended state: an unpinned release is worse than a red build.

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
2. Pick the branch (or tag) to build. Leave **`build_only` ticked**.
   Optionally set `xcode` to try a specific toolchain.
3. When the run finishes, the IPA is under *Artifacts* on the run page
   (`VexSign-<version>-<sha>`, kept for 14 days). The run summary links to it.

Nothing else happens: no release, no tag, no `app-repo.json` change. Pull
requests against `main` get exactly this treatment automatically, so a PR's
run page also has an installable IPA.

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

## Manual publish (escape hatch)

Unticking `build_only` publishes `v<MARKETING_VERSION>` from the head of the
selected branch. It exists for the cases a tag push can't cover - mainly
creating a **draft** release to review the notes before they go live (tick
`draft`; GitHub creates the tag when you publish the draft). Guard rails:

- the tag is created at the **exact commit that was built**, not wherever the
  branch head is by the time the build finishes;
- it **refuses to run if the tag already exists**, so a published release is
  never silently overwritten by a branch build. Bump `MARKETING_VERSION`, or
  re-run the tag's own workflow run instead;
- `prerelease` / `draft` inputs apply only to this mode.

Dispatching with `build_only` unticked *on a tag* re-publishes that tag from
the same source (the version checks still apply); it is equivalent to
re-running the tag's run.

## When something goes wrong

| Symptom | What it means | Fix |
| --- | --- | --- |
| `v1.2.0 does not match the project's MARKETING_VERSION (1.1.0)` | The tag was pushed before the version bump landed. | Bump the version, commit, move the tag onto that commit (`git tag -f v1.2.0 && git push -f origin v1.2.0`). |
| `The built app reports CFBundleShortVersionString 1.1.0, but v1.2.0 promises 1.2.0` | Same thing, caught after the build (targets disagreed on the version, so the pre-build check was skipped). | Set the same `MARKETING_VERSION` on every target and re-tag. |
| `v1.2.0 already exists on origin; refusing to overwrite` | A manual publish targeted a version that is already released. | Bump `MARKETING_VERSION` for a new release. To re-publish the existing one, re-run its tag's workflow run. |
| Tag push did nothing | The tag doesn't match `v<major>.<minor>[.<patch>][-<suffix>]`. | Delete it and push a correctly named tag. |
| Build failed on a tag push | Same failure a PR would have shown. | Fix on `main`, then re-tag the fixed commit. Nothing was published. |
| Release exists but `app-repo.json` didn't update | `Update Repository` failed or ran before the assets were visible. | *Actions → Update Repository → Run workflow* with `tag` = `v1.2.0`. |
