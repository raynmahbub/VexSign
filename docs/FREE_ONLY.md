# Free-only operation

This repository is configured to avoid paid AI services and use standard GitHub
Actions infrastructure for a **public** repository. This is a cost-avoidance
configuration, not a financial guarantee against account-level usage or future
provider pricing changes.

## Enforced by repository code

- No hosted model inference calls or model workflow permissions. AI repair is
  replaced with diagnostic issues and human/local fixes.
- Every workflow job checks `github.event.repository.private == false` before
  allocating a runner. Private copies skip jobs; they do not fall back to paid
  minutes. This includes manual, scheduled and publishing jobs.
- Only standard `ubuntu-24.04` / `macos-15` runner labels; no larger runners or
  self-hosted infrastructure is provisioned.
- Actions upload retention capped at **three days**, including build logs, test
  results and preview artifacts. GitHub Release assets are separate from Actions
  artifacts and remain subject to GitHub's service policies.
- Regression checks reject model permissions/endpoints, unapproved runner labels,
  missing public-only gates and longer artifact retention.

## One-time account checks (required for zero spend)

1. Keep the repository **public** and confirm standard hosted Actions are covered
   by GitHub's current public-repository allowance/terms for your account.
2. In GitHub billing, disable paid model usage and any paid Actions/storage usage
   where controls are available. Use enforced zero-spend limits / stop-usage
   controls, not an alert-only budget. Available settings vary by account/plan;
   if GitHub does not offer an enforceable limit for a service, disable that paid
   service rather than assuming an alert prevents charges.
3. Do not select larger runners, buy an agent subscription, or provision cloud
   services for this automation. Optional VexSign servers/cloud signing are not
   deployed by these changes; hosting those separately may cost money.
4. Check current Actions cache/artifact storage. Delete unneeded existing data;
   lowering retention in YAML applies to **new** uploads, not old artifacts.
5. After merging this PR, cancel old runs that used the earlier repair workflow
   and disable any separately configured model/agent integrations. New policy
   does not retroactively rewrite an already-running workflow.
6. Monitor the account's usage/billing page occasionally. Organisation policies,
   other repositories and historical charges are outside this repository's control.

Live billing settings have not been inspected or changed here. Never share a
billing credential or provider key in chat. The new configuration is active only
after it reaches the default branch; PR validation uses its candidate code.

## What you give up

There is no automatic hosted-AI code generation. Deterministic maintenance,
validation, eligible dependency merges, changelogs and release automation remain.
Hard failures and sensitive changes are escalated for human/local repair.

Disable a workflow in Actions if you want it to stop completely. GitHub can delay
schedules or disable inactive repository schedules; “free” does not imply an
availability guarantee. Continue real-device testing before shipping.
