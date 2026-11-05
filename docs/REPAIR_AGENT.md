# Free-only repair diagnostics

Hosted AI repair generation has been **removed** to honour the zero-cost
requirement. The `Repair diagnostics` workflow records failures; it does not call
GitHub Models, paid APIs, coding agents or a self-hosted inference server.

Setting the old `REPAIR_AGENT_ENABLED` or `REPAIR_MODEL` variables cannot enable
inference. The inference client/endpoint and `models: read` workflow permissions
are gone. Even a direct invocation of `repair-agent.py propose` fails before any
network call. The offline proposal validator remains available for testing/local
work, but the workflow does not publish generated repair PRs.

## What remains automatic

- Existing build/test validation, dependency maintenance and eligible green bot
  merges through [autopilot](AUTOPILOT.md).
- Nightly pre-releases, version-bump-triggered stable packaging, release notes,
  assets/checksums and stable-listing PRs.
- Failure triage and bounded diagnostic issues: current public-repository main
  CI/companion failures only, deduplicated by source commit, at most two diagnostic
  reservations per UTC day. Closing an issue does not reset the reservation.

Fixes requiring judgment now need you or a local coding tool. There is no promise
of unattended arbitrary code repair for free. No model receives source, logs,
credentials or prompts. Physical-device acceptance remains manual.

Set `FREE_DIAGNOSTICS_ENABLED=false` to pause the extra diagnostic issues. Ordinary
CI triage is independent. Re-running a diagnostic workflow does not authorize
inference; that capability is not present in this mode.

## Cost controls

All repository workflow jobs are gated to public repositories before runner
allocation and use only standard `ubuntu-24.04` or `macos-15` hosted runners.
Uploaded Actions artifacts expire after at most three days. The gates mean that
changing repository visibility to private skips these workflows rather than
consuming private-repository runner minutes.

These controls cannot change account billing, GitHub pricing, existing artifacts,
cache usage, other repositories or old workflow runs. For a strict zero-spend
setup, also follow [Free-only operation](FREE_ONLY.md). No account billing changes
have been made by this patch.

`make verify` includes offline tests for the no-inference hard stop, standard
runners, public-only guards and short artifact retention. No test spends tokens.
