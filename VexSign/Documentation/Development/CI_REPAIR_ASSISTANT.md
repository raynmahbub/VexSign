# CI repair assistant

The optional **CI repair assistant** reacts to a failed `CI` run for an open
pull request from a branch in this repository. It is an aid for straightforward
compile/test failures—not a guarantee that every bug can be diagnosed or fixed.

## Enable it

In **Settings → Secrets and variables → Actions**:

1. Add the repository secret `OPENAI_API_KEY` for the OpenAI account that should
   pay for repair requests.
2. Optionally add the repository variable `BUGFIX_AGENT_MODEL` to override the
   default `gpt-4.1-mini` model.

Without the secret, the workflow writes a notice and safely skips model calls and
PR creation. The repair workflow must first be merged to the default branch; GitHub
runs `workflow_run` workflows from that trusted branch. Review provider usage and
set an appropriate spending limit before enabling it.

## What it does

1. It responds only to failed `CI` runs for open, same-repository pull requests.
   Forks and the assistant's own `automation/bugfix-agent/` branches are excluded.
2. A read-only job sends a bounded excerpt of the failed logs, the PR diff, and
   changed Swift source to the configured model. The model has no shell/tools and
   cannot access repository write permissions.
3. The proposed unified diff must modify existing Swift files already changed by
   that PR. Workflow, dependency, build-configuration, signing/security and
   unrelated files are outside the allowlist. The patch is limited to 80 KB and
   800 changed lines; large or unsupported cases are skipped.
4. A separate no-secret validation job checks patch scope and applicability at the
   exact failed commit. A write-enabled publisher rechecks the source PR and
   publishes the patch as a **draft replacement PR** against the default branch.
   That replacement includes the original PR changes plus the proposed correction,
   so the normal CI workflows validate it.

The assistant does **not** push to or change the original PR, approve or merge its
replacement, retry arbitrary failures, or run untrusted PR scripts with write
credentials. A person must review the complete replacement diff and CI results;
close the original PR only if the replacement is accepted. Each failed head commit
can produce at most one candidate branch, and the assistant ignores its own repair
branches to prevent loops.

Existing deterministic maintenance automation is separate: it can auto-merge
only the narrowly allowlisted bot updates documented in [Maintenance](MAINTENANCE.md).
It does not auto-merge AI-proposed source changes.
