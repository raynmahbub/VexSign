# Repository automation and maintenance

VexSign uses automation for work that is deterministic, reviewable and safe to
repeat. It does **not** silently rewrite application behaviour: a signing or
SwiftUI bug needs a reproducer, a regression test and a build.

## Dependency updates

[`.github/dependabot.yml`](../.github/dependabot.yml) keeps the supported
dependency graphs current:

| Ecosystem | Path | Cadence |
| --- | --- | --- |
| GitHub Actions | `/` | Daily |
| Python (`server/requirements.txt`) | `/server` | Weekly |
| npm (`cloud-signing/package-lock.json`) | `/cloud-signing` | Weekly |
| SwiftPM | `/NativeSigning`, `/SideSign`, `/Vendor/Zsign` | Weekly |
| Docker | `/server`, `/cloud-signing` | Weekly |

Patch and minor updates are grouped to keep the PR queue small; major updates
arrive separately so their migration notes are not hidden in a bundle. Dependabot
never pushes to `main`.

The Xcode app's own Swift packages are declared in
`VexSign.xcodeproj/project.pbxproj`, not in a `Package.swift`, so Dependabot
cannot update them directly. Refresh them deliberately on a macOS checkout:

```bash
make audit-packages   # read-only report, also runs weekly in Actions
make bootstrap
# bump the relevant repository/requirement in project.pbxproj, then:
xcodebuild -workspace VexSign.xcworkspace -scheme VexSign \
  -resolvePackageDependencies
make verify
make test
```

Review the resolved graph in
`VexSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` and
build before committing. Root packages are pinned because Xcode, iOS SDK and
SwiftUI compatibility matter more than being newest.

Enable **Dependabot alerts** and **security updates** under Settings → Code
security for advisory-driven fixes. GitHub Actions are also reviewed by the
pinned-SHA policy in `tools/test_workflow_policy.py`.

## Automated hygiene, not automated guessing

**Repository maintenance** (`.github/workflows/repo-maintenance.yml`) runs on
Mondays and on demand. It:

1. runs `python3 tools/sync-strings.py --write` to add missing English
   localisation keys;
2. runs `make verify`;
3. opens or refreshes a review PR **only if files changed**.

It never commits to `main` and never edits Swift behaviour. `sync-strings` is a
mechanical, idempotent tool; that is why it is safe to automate.

**CI triage** (`.github/workflows/ci-triage.yml`) watches the `CI` workflow. A
failure on `main` opens (or comments on) an issue containing the commit, run URL
and failed jobs, so a red run is not lost in the Actions tab. It does not invent
a patch.

## What is intentionally manual

- Merging Dependabot or maintenance PRs. Path-filtered app, server, cloud and companion validators run on PRs
  automatically. Review all affected build/test results, not just the app check.
- Updating the root Xcode SwiftPM requirements (see above).
- Changing signing, provisioning, entitlements or installation behaviour.
- Publishing a stable release. Pushing a `v<MARKETING_VERSION>` tag is the
  automated path; the version bump itself is a reviewed commit.

## Automation boundaries

Automate checks, packaging, immutable nightlies and mechanical maintenance PRs.
Do not auto-merge signing/security changes or promote nightlies to stable. A green
build is not proof of real-device installation, entitlement correctness or safe
credential handling. Configure required checks, protected release environments
and tag rulesets in GitHub; workflow YAML alone cannot enforce those settings.

## Current release state

- `MARKETING_VERSION`: **1.1.0**
- Stable channel: tag push or **Actions → Release**, channel `stable`
- Nightly channel: daily 03:00 UTC, or channel `nightly` manually
- Nightly releases are pre-releases and never update `app-repo.json`

See [Releasing](RELEASING.md) for the exact tag, environment and verification
rules.
