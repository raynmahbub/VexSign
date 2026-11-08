# Repository operations

One guide for deterministic repository automation, optional paid CI repair,
dependency maintenance and occasional human checks. Build commands live in
[Build](BUILD.md); version/channel/environment rules live in [Releasing](RELEASING.md).
Security and device acceptance stay separate.

## Your normal routine

1. Add features in a PR and review the relevant build/test results.
2. To ship stable, increase **all** `MARKETING_VERSION` values consistently to a
   higher `major.minor.patch`. Optionally add `docs/releases/<version>.md` highlights.
3. Merge. Full CI validates main; a successful current-main version increase queues
   Release, which builds/tests again before protected publishing. Nightlies run
   independently every day at 03:00 UTC / 09:00 Dhaka.
4. Occasionally review failure issues, major upgrades, conflicts and pending
   approvals. Signing/provisioning/security changes and real-device tests need you.

A bounded AI repair assistant is available for eligible failed same-repository PRs; it proposes a draft replacement PR and never merges source-code changes. It requires the optional `OPENAI_API_KEY` Actions secret. See [CI repair assistant](CI_REPAIR_ASSISTANT.md) for its limits and setup.

## Workflow map

| Workflow | Responsibility / cadence |
| --- | --- |
| **CI** | Relevant app PRs/main changes: portable gates, unsigned iOS build, simulator tests. |
| **Service checks** | Server/cloud edits: Python tests, TypeScript build/tests/contracts and production dependency audit. Also weekly Tuesday advisories; both cheap suites run together. |
| **Platform check** | Relevant companion/shared-package changes: tvOS, watchOS and visionOS builds. |
| **Documentation** | Documentation edits: cheap offline file-link checks; no macOS work. |
| **Release** | Daily nightlies, tag/manual stable builds, CI-driven version-bump dispatch and isolated protected publication. |
| **Repository maintenance** | 4-hourly bot-PR controller; weekly hygiene/audit; main-failure triage with isolated permissions. |
| **CI repair assistant** | Failed same-repository PR CI: optional AI-proposed, allowlisted draft replacement PR; never auto-merges. |
| **Update Repository** | Published stable metadata → listing review PR, never a direct main push. |
| **Combined native host · build only** | Manual experimental container preparation/build (dispatch with `link_smoke` for native link diagnostics); no normal release publication. |

Separate files remain where triggers, SDK costs or permissions differ. Existing
app/server/cloud/documentation check names are retained. If an organisation rule
selects workflows by **file**, update its service selection to `services.yml`;
repository YAML cannot inspect or migrate live protection rules automatically.

## Deterministic bot maintenance

**Repository maintenance → bot-prs** runs every 4 hours. The trusted-default-branch
controller accepts only same-repository, non-draft PRs from:

- Dependabot: patch/minor service dependency updates restricted to
  `server/requirements.txt` or `cloud-signing/package*.json`, with update metadata;
- GitHub Actions: `automation/repo-maintenance` changing only the localisation
  catalogue, or `automation/release-listing` changing only `app-repo.json`.

It refreshes a stale branch only when GitHub can merge main without conflicts,
then validates the new head on a later pass. It explicitly dispatches full CI and
service checks where needed, merges at most one green/current PR per pass with a
pinned head SHA, then explicitly dispatches main validation. Explicit dispatch is
necessary because `GITHUB_TOKEN`-created PRs/merges do not trigger ordinary events.
No personal token, external GitHub App or autonomous approval is required.

Human features, major upgrades, Docker/Actions updates, Swift packages, application
source, workflow/signing/security changes, forks, conflicts and unknown bot
branches are **not** auto-merged. Failed checks are not repeatedly retried. Required
reviews/queues/environment protections are never bypassed.

**Repository maintenance → hygiene** runs weekly, adds missing English
localisation keys, runs `make verify`, and opens/refreshes a PR only when the
catalogue changes. **audit** is a separate read-only-source job that reports root
Xcode package updates in an issue. Hourly runs do not repeat these weekly jobs.
Manual tasks: `all`, `bot-prs`, `hygiene`, `audit`.

## Dependencies

Dependabot groups patch/minor updates and opens majors separately. It covers
Actions daily and server Python, cloud npm, local SwiftPM packages and Docker
weekly; see [the configuration](../.github/dependabot.yml).

The app's root SwiftPM requirements live in `project.pbxproj`, outside Dependabot's
SwiftPM support. For a reviewed root update on macOS:

```bash
make audit-packages
make bootstrap
# Deliberately update the requirement in project.pbxproj, then resolve:
xcodebuild -workspace VexSign.xcworkspace -scheme VexSign -resolvePackageDependencies
make verify
make test
```

Review the resolved package graph and build before merging. Enable Dependabot
alerts/security updates in GitHub's repository settings for advisory-driven fixes.

## One-time activation and occasional checks

1. Merge the configuration to the default branch; scheduled/controller workflows
   activate there. No live protection or billing settings are changed by YAML.
2. Allow Actions to create PRs. Organisation policies may restrict requested token
   permissions. Bots do not approve their own PRs.
3. Protect main with PR/check requirements and protect release tags/workflows.
   Required human reviews deliberately block unattended bot merges; choose rules
   appropriate to narrow metadata/service updates without adding admin bypasses.
4. Configure `build-preview`, `nightly` and `release` environments per
   [Releasing](RELEASING.md). Required stable reviewers pause publication by design;
   keep them unless you explicitly choose unattended stable publication.
5. Run **Repository maintenance → all** once and inspect its log. Enable Actions
   and issue notifications. GitHub can delay schedules or disable inactive ones.
6. Cancel obsolete runs when replacing workflows. Lower retention affects new
   uploads, not old artifacts. To activate the CI repair assistant, add the
   `OPENAI_API_KEY` Actions secret; set `BUGFIX_AGENT_MODEL` as an Actions variable
   only if you want to override its default model. The workflow skips safely when
   the secret is absent. Review its draft PRs manually.

If main advances before version-bump CI finishes, stable dispatch skips the old
candidate. Review the current commit and use the normal manual Release dispatch.
No version bump means nightly-only; published versions/tags are never overwritten.

## Free-only cost controls

Every job requires an explicitly **public** repository before runner allocation.
Private copies skip jobs rather than using private-repository minutes. Only
standard `ubuntu-24.04` / `macos-15` runners are allowed. Diagnostic and
release-staging uploads retain artifacts for at most **three days**; temporary unsigned CI IPA bundles retain
for **14 days** for device testing, including the opt-in combined-host prototype
IPA/source/verification bundle. Combined-build logs remain at **three days**.
Existing uploads keep their original expiry.
There are no model permissions, inference calls, larger runners, paid agents or
provisioned self-hosted services.

For a strict zero-spend account setup, also:

- Confirm standard public-repository Actions are covered under your current GitHub
  account's terms. Pricing/allowances can change.
- Disable paid usage or use enforced zero-spend/stop-usage controls where offered;
  an alert-only budget does not prevent charges. If a service has no enforceable
  spending control, disable it rather than assuming the budget is a cap.
- Review/delete unneeded existing caches/artifacts and check account usage
  occasionally. Other repositories, old runs, historical charges and independently
  hosted optional services are outside this repository's control.

These are cost-avoidance controls, not a financial or availability guarantee.
Physical-device acceptance remains required: use [Device testing](DEVICE_TESTING.md).

## Pause switches

Set Actions variables to the literal `false`:

- `AUTOPILOT_ENABLED`: stop scheduled bot validation/merging (every 4 hours; weekly audit/hygiene remain).
- `AUTORELEASE_STABLE`: stop CI-driven stable dispatch (manual/tag release remains).

Unset means enabled. Disable the relevant workflow to stop scheduled operations
entirely, and cancel already-running jobs separately. Never commit credentials.

## Build cost and workflow boundaries

Ten workflow entry points are retained intentionally: CI, documentation, service
checks, companion platforms, Release, combined host, opt-in native link diagnostics,
repository maintenance (including failure triage), the constrained CI repair assistant,
and stable listing updates.
Triage deliberately does not watch its own maintenance workflow: even skipped
workflow runs emit completion events. Maintenance's own failures remain visible
through GitHub Actions notifications rather than recursively opening issues.
Documentation/services do not need macOS. Optional native link diagnostics run
only on request. Release/listing write permissions never run PR code.

CI examines the complete PR diff, not just its latest commit. Known portable
Python tooling/changelog/docs-only changes keep Linux gates but skip the native
build/test jobs. App, test, native module, dependency, build configuration and
unknown changes keep full native validation. Missing history defaults to full
validation; manual full CI also forces native checks. Check names are retained;
repository protection rules requiring a specific workflow file should be reviewed
when consolidating the removed `ci-triage.yml`.

Combined-host dependency downloads are cached by OS, architecture, selected
Xcode and lockfiles. No signed output or final build products are restored.
Simulator test workers are bounded to two to limit clone startup/oversubscription.
These are cost controls, not measured timing guarantees: hosted macOS queue
capacity is outside this repository's control. Source changes still require
compilation and tests; production release builds still test their exact commit.

A native-primary package is not proof of end-to-end Apple signing, installation,
unattended renewal or physical-device acceptance. Workflow consolidation does not
remove those implementation/validation boundaries.
