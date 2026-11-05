# Low-maintenance repository operation

You write features and review exceptional changes. Actions handles deterministic
maintenance, tests, packaging and releases. This is not an autonomous developer:
it does not invent features, guess fixes to failing code or fabricate device tests.

## What happens automatically

| Work | Behaviour |
| --- | --- |
| Feature PRs | Existing path-filtered validation; humans decide feature merges. |
| Dependency updates | Dependabot opens grouped patch/minor PRs and separate major PRs. |
| Eligible service dependency PRs | Hourly controller validates actual Dependabot authors, update metadata and exact allowed files; major updates excluded. |
| Localisation and stable listing PRs | Only GitHub Actions-owned, named automation branches and exact allowed files qualify. |
| Stale eligible branches | Ask GitHub to merge main into the branch, only if conflict-free; never guess conflict resolutions. Validate the new SHA on the next pass. |
| Bot-PR checks | Explicitly dispatch full CI plus affected server/cloud validators, avoiding GITHUB_TOKEN event suppression. |
| Bot-PR merging | Merge one green, current candidate per hourly pass; pin head SHA, honour repository rules, never use admin bypass/auto-approval. |
| Post-merge validation | Explicitly dispatch main checks after token-created merges. |
| Nightlies | Daily 03:00 UTC / 09:00 Dhaka; immutable pre-release, simulator gate, assets/changelog/checksums. |
| Stable releases | After green full CI on main, detect an unanimous, increased `MARKETING_VERSION` compared with its first parent; dispatch Release automatically. |
| Failure reporting | Main failures in CI, companions, services, release and maintenance/controller workflows open triage issues. |

The controller never runs PR code with its write-enabled token. It checks out
trusted default-branch scripts and dispatches separate read-only validators.
It does not retry failed checks indefinitely. A failed run blocks merging until
someone investigates and reruns the appropriate workflow for the same candidate.

### Intentionally not auto-merged

- Human-authored feature PRs, forks, drafts and unknown automation branches.
- Major dependency updates, Docker runtime upgrades and GitHub Actions updates.
- Swift packages, signing/provisioning behaviour, application source and workflow
  changes, even if a PR has a convenient label or “bot” in its title.
- Conflicts, failed checks, missing checks, required reviews and protection errors.

## One-time activation

1. Merge these workflow/tool changes into the default branch. Scheduled workflows
   and `workflow_run` controllers only become active from there.
2. In Actions settings, allow GitHub Actions to create PRs. The named workflows
   request scoped write permissions; organisation policies may still restrict them.
   They never approve their own PRs.
3. Configure main rulesets: require PRs and checks, do not allow direct bot/admin
   bypass. Required human review rules will intentionally prevent unattended merges;
   decide whether narrow service/metadata updates may merge on checks alone using
   GitHub's supported ruleset capabilities. This controller never overrides rules.
4. Configure `build-preview`, `nightly`, and `release` environments as described in
   [Releasing](RELEASING.md). Required release reviewers intentionally pause stable
   publication; remove that requirement **only if you choose unattended stable
   publishing**. Keep source/workflow/tag protections and no signing secrets in CI.
5. Run **Repository autopilot** once and inspect its log. Then the hourly schedule
   handles eligible bot PRs. GitHub schedules can be delayed; inactive public
   repositories can have schedules disabled by GitHub.
6. Enable Actions failure notifications/issue notifications. Check triage issues,
   major upgrades and pending approvals when you visit the repository.

No personal access token or paid external agent is required. The controller uses
`GITHUB_TOKEN` and explicit workflow dispatch to overcome event suppression for
bot-created PRs/merges. It does not claim to change live settings through YAML.

## Your normal feature workflow

1. Add features in a PR and inspect the CI results.
2. For a stable release, update **all** project `MARKETING_VERSION` settings to a
   higher `major.minor.patch` in that PR; optionally add reviewed highlights in
   `docs/releases/<version>.md`. Keep versions consistent across targets.
3. Merge it. Full CI on that exact main commit must pass. Automatic stable release
   queues the existing protected Release workflow, which builds/tests again and
   publishes notes, visuals, metadata and checksums.
4. The stable listing updater opens a narrow PR. Autopilot validates and merges it.

If another main commit arrives before the version-bump CI completes, automatic
stable release deliberately skips the obsolete candidate. Use the normal manual
Release dispatch on the desired current main commit after reviewing its checks.
Published versions/tags are never overwritten. No version bump means nightly-only;
a dependency merge does not magically become a stable release.

## Pause switches

Set these repository Actions variables to the literal string `false`:

- `AUTOPILOT_ENABLED`: stop automated bot-PR dispatch/merge.
- `AUTORELEASE_STABLE`: stop version-bump-triggered stable dispatch.

Unset means enabled. Disable the Release schedule workflow separately to stop
nightlies. A workflow already running may need cancellation in Actions. Secrets,
release approvals, physical-device checks and feature design still need people.


## Free-only failure diagnostics

The [free-only policy](FREE_ONLY.md) disables hosted inference and gates all jobs
to public repositories/standard runners. [Repair diagnostics](REPAIR_AGENT.md)
records bounded failure issues instead of generating code. No model-access opt-in
variable can restore the removed inference client. Fixes require human/local work;
the deterministic maintenance/release automation above remains available.
