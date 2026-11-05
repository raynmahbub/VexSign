# Bounded repair agent

`Repair agent` is an **opt-in proposal service**, separate from the deterministic
[repository autopilot](AUTOPILOT.md). It is not a general autonomous developer and
never approves/merges its own fixes or publishes releases.

## What it does

1. Watch failed **CI** and **Platform check** runs on the current default-branch
   commit. Accept push/manual validation runs from this public repository only;
   reject forks, PR branches, private repositories, obsolete commits and unrelated
   workflows. Manual invocation takes a workflow run ID, not a prompt/command.
2. Reserve an attempt in a `Repair attempt: <full source SHA>` issue. Existing open
   **or closed** attempts prevent a repeat. At most **two reservations per UTC day**
   across all admitted failures. The entire workflow is serialized.
3. Read failure annotations for allowed presentation files. Send only those
   annotations (bounded, with common credential/email patterns redacted) and at
   most two small public source files to GitHub Models. Never send raw build logs,
   signing material, issue instructions or the whole checkout.
4. Make **one** inference request: at most 36 KB of user context, 6,000 output
   tokens, a 90-second HTTP timeout and a 150 KB response cap. No tools, shell,
   model-selected URLs, package installation, or automatic retry. A policy failure,
   refusal, missing evidence, rate limit or unavailable model becomes escalation.
5. Validate the JSON response and transfer only proposal data through a run-bound
   artifact. An independent write-enabled publisher revalidates the current source
   SHA, file hashes, path policy, size and regression-test requirements.
6. Publish a normal `automation/repair-<SHA>` PR and explicitly dispatch full CI
   and companion builds. This avoids bot-token event suppression. Comment the
   outcome on the attempt issue. **You review semantics and test quality before
   merging**, even when all checks pass.

There is no checkout/build/execution of proposed code in the write-enabled job.
Candidate code is compiled/tested only by the existing separate read-only
validators. The inference job has `contents: read`, `actions: read`, `models: read`
and no repository write permissions. It does hold its limited API credential to
call GitHub Models; credentials are headers, never model context.

## Initial scope

An accepted repair must modify an existing Swift presentation source in:

- `VexSign/DesignSystem/*.swift` (direct children only);
- `NimbleKit/Sources/NimbleViews/Views/*.swift` (direct children only);
- `NimbleKit/Sources/NimbleViews/NBMetrics.swift`.

It must also add a **new** `VexSignTests/Repair<Name>Tests.swift` XCTest regression
file. Existing tests may not be edited. Maximum three files, 200 inserted/deleted
lines, and 24 KB per proposed file. Symlinks, traversal, deletes, no-ops, duplicate
paths and stale hashes are rejected. All edits are revalidated before publishing.

Workflow/policy code, packages/lockfiles, signing, provisioning, authentication,
network services, credentials, entitlements, installation and release configuration
are outside the allowlist. Infrastructure failures, inaccessible logs/annotations,
large source files and failures without allowed-file diagnostics remain manual.
No attempt is made to automatically resolve arbitrary conflicts or major upgrades.

The gate enforces scope and presence of test syntax, **not test usefulness or safe
Swift behaviour**. A presentation file can still contain dangerous code. Review is
mandatory; do not extend the existing autopilot to merge these PRs merely because
the author is a bot or a model says the change is safe.

## Activation and billing

1. Merge the workflow, trusted tools and tests to the default branch first.
2. Enable GitHub Models access for this repository/organisation and confirm the
   selected model is available under your GitHub account's terms/region/policy.
   The workflow uses the ephemeral `GITHUB_TOKEN` with `models: read`; it does not
   need a personal token or a model provider key in chat/repository files.
3. Allow Actions to create PRs. Ensure repository/organisation policies permit the
   narrowly scoped job permissions. Existing main/release protections remain in
   force. Do not add an admin bypass or autonomous self-approval.
4. Set Actions variable **`REPAIR_AGENT_ENABLED=true`** only after reviewing the
   data flow and spending policy. Unset/anything else means disabled.
5. Optional **`REPAIR_MODEL`**: `openai/gpt-4.1-mini` (default) or `openai/gpt-4.1`.
   Unknown models fail closed. This is a hosted model request, not a local model.
6. Keep paid model usage off unless desired; if you enable paid GitHub Models,
   configure a provider/platform spending budget and alerts. Token/attempt bounds
   limit requests but **are not a dollar-denominated spending cap**. Rates, account
   quotas and free-tier availability can change. Rate limits do not cause retries.
7. For a real smoke test, manually run **Repair agent** with a current supported
   failed-main run ID. Inspect the tracking issue, proposal PR and separate CI.
   Local tests are mocked: they do not prove your account has model access.

Re-running failed jobs does not authorize another inference call: admission,
proposal and publication all require `github.run_attempt == '1'`. A new workflow
run for the same source SHA is also blocked by the durable attempt issue. Do not
delete the tracking issues to work around budgets. Closing them is safe and does
not reset the reservation. A new source commit can receive a new attempt within
the daily limit. Unsupported/no-fix attempts still consume their reservation.

To pause, unset `REPAIR_AGENT_ENABLED`, set it to `false`, or disable the workflow.
Cancel an already-running job separately. Issue/Actions notification settings
should alert you to failed/no-proposal outcomes. Pending approvals, signing keys,
production secrets and physical-device acceptance must remain human controlled.

## Data and evidence

Only public repositories are supported by this initial implementation. Redaction
is best-effort, not a proof that an annotation contains no secret. Keep build
output free of secrets; rotate any leaked credential. GitHub Models processes the
bounded public source/diagnostic context; review its applicable retention and data
terms before opting in. Generated proposal artifacts are retained for seven days.
There is no model reasoning trace or raw diagnostic archive uploaded by this job.

A CI pass or convincing model explanation is not proof of installation on iOS.
Continue the [physical-device acceptance procedure](DEVICE_TESTING.md). This agent
never claims to have run hardware tests or substitutes generated images/evidence.

## Tests

`make verify` includes offline policy/budget/workflow tests. They cover path and
symlink attacks, stale hashes, sensitive files, existing-test protection, malformed
schemas, budgets, redaction, origin/default-branch checks and permission separation.
They neither spend model tokens nor create GitHub issues/PRs.
