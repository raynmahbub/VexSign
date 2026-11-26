# Cloud signing service: deployment and verification

This is an optional backend, not part of the standalone iOS app. **No production
signing engine or sandbox is bundled.** Never expose a deployment that invokes an
unsandboxed signer on user uploads.

## Build and test

Use Node 22 and a disposable PostgreSQL 17 / Redis 7 instance for integration tests:

```sh
cd Services/Cloud
npm ci
npm run build
npm test
TEST_DATABASE_URL=postgres://postgres:integration@127.0.0.1:5432/vexsign_test \
TEST_REDIS_URL=redis://127.0.0.1:6379 npm test
npm run contracts
```

Without `TEST_DATABASE_URL` / `TEST_REDIS_URL`, the corresponding integration tests
are explicitly skipped. The database role must be able to create/drop schemas;
never point tests at production. CI provisions both services. S3 failures use fakes;
a real S3/signer/device acceptance test is still required before production use.

## Configuration

Copy `deployment.env.example` to a **local, untracked `.env` file**, replace all
placeholders, and inject it through your deployment's secret manager. Node does
not automatically load this file; use your orchestrator's environment injection
or `node --env-file=.env dist/API/main.js`. Never commit the filled template.

- `DATABASE_URL`: PostgreSQL DSN; use authenticated TLS for remote databases.
- `REDIS_URL`: Redis DSN; prefer authenticated `rediss://` across hosts.
- `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`: private HTTPS object store. Supply AWS
  credentials via workload identity or the AWS SDK's standard credential chain.
- `S3_KMS_KEY_ID`: optional KMS key; otherwise uploads request AES256 server encryption.
- `PUBLIC_ORIGIN`: externally reachable bare HTTPS origin, with no path or query.
- `JWT_PUBLIC_KEY_FILE`: mounted PEM RSA public key. The external identity provider
  retains the private key and issues RS256 tokens with matching issuer/audience,
  nonempty `sub`, `scope` containing `signing:write`, `iat`, and `exp`. Lifetime
  must be at most one hour. The service does not mint user tokens.
- `ENCRYPTION_KEY`: 32 random bytes encoded as 64 hex characters; generate with
  `openssl rand -hex 32`. Share across API/worker replicas. Store securely: changing
  it invalidates existing envelopes, idempotency fingerprints and install links.
- `SIGNER_EXECUTABLE`: absolute path to the operator-provided sandbox launcher.
  Required by shared configuration even for API-only deployments.
- `SIGNING_CONCURRENCY`: 1–8, default 2; size according to sandbox resource limits.
- `WEBHOOK_ALLOWLIST`: comma-separated exact HTTPS endpoint URLs, default empty.
- `TRUSTED_PROXIES`: comma-separated trusted proxy IPs/CIDRs; empty by default.
  Do not trust arbitrary proxies or expose an origin that bypasses your edge policy.
- `PORT`: default 8080. API binds to `0.0.0.0`.

## Deploy and smoke-test

1. Build with `docker build -t vexsign-cloud Services/Cloud` from the repository root.
2. Provision PostgreSQL, Redis and a private S3 bucket. Block public bucket access,
   encrypt at rest, use least-privilege credentials, and enforce HTTPS.
3. Run `npm run migrate` (or the image's `node dist/Storage/migrate.js`) with
   `DATABASE_URL`. Migrations are transactional and guarded by an advisory lock.
   **Apply migration 003 before starting this version's API or worker.**
4. Start API with `npm start`. Start a separate worker with `npm run worker`, with
   the same database, Redis, bucket, JWT configuration and encryption key. Mount
   the sandbox launcher and its dependencies into the worker image/environment;
   the stock API image does not provide them.
5. Probe `/health/live` and `/health/ready`. Disconnect Redis in staging and confirm
   readiness/API requests fail within a bounded interval, then recover on reconnect.
6. Use a short-lived test JWT to upload owned `p12`, `provision`, and `ipa` multipart
   files via `/api/upload?kind=...`; submit `/api/sign` with a UUID
   `Idempotency-Key`; poll `/api/jobs/{id}`. See `openapi.json` for wire schemas.
7. Verify the output SHA-256 and Apple signatures independently, then install on an
   authorized test device. A mock protocol response is not signing acceptance.

## Signer protocol and sandbox boundary

`Signing/CloudSigningCoordinator/signer.ts` sends one JSON document on stdin:
`protocolVersion: 1`, `kind` (`sign` or `check-cert`), `directory`, `p12Path`,
`provisionPath`, `outputPath`, `password`, and, for signing, `ipaPath`.
No shell is used; passwords must never be copied to argv, logs, or environment.

For signing, write the output IPA at `outputPath`, verify it, then return only:

```json
{"kind":"sign","signatureVerified":true,"metadata":{"name":"Example","bundleIdentifier":"com.example.app","version":"1.0","changelog":"","screenshotURLs":[]}}
```

Never assert `signatureVerified: true` without real verification. A certificate
check returns `kind: "check-cert"` and a `certificate` object matching
`API/DTOs/contracts.ts`. `Examples/mock-signer.mjs` provides a **non-signing**
protocol smoke-test fixture; it refuses signing operations and reports unknown
certificate status. Do not use it in production.

The launcher must enforce isolated extraction, no path traversal/symlink escapes,
CPU/memory/disk/process limits, a bounded filesystem view, and no network access.
Keep credentials scoped to the job. The parent enforces a ten-minute signer
limit and one-MiB stdout limit and kills the process group, but those are not a
sandbox. Nonzero exit or malformed/mismatched output fails the job. Worker death
can leave temporary job directories; provision an ephemeral encrypted work volume
and an operator-controlled stale-directory cleanup policy when no worker uses it.

## Recovery, cleanup, and retention

- API Redis commands have finite retry/timeout budgets and no offline queue;
  workers keep reconnecting. Tenant throttling remains fail-closed.
- The dispatcher reconciles PostgreSQL and BullMQ every five seconds in bounded
  pages. Missing/completed Redis deliveries with an abandoned running claim are
  requeued only after the 30-minute safety window. This is not instantaneous
  crash recovery; alert on unusually old queued/running rows.
- Input deletion is serialized with tenant submissions. Committed deletion intent
  makes an input unavailable to new jobs **before** S3 deletion. Failed deletes
  remain eligible for the periodic retry sweep. Terminal jobs release unreferenced
  inputs immediately; unused uploads become eligible after 24 hours.
- Outputs expire seven days after the terminal job timestamp. The worker deletes
  S3 objects before clearing their database keys, retaining failed deletes for
  retry. Install URLs do not extend artifact retention. Jobs and audit rows remain
  in PostgreSQL; define a separate database archival policy appropriate to your
  compliance requirements.
- Configure S3 lifecycle rules as a safety net for **orphaned** objects and
  incomplete multipart uploads. Aborting incomplete multipart uploads after one
  day is recommended. Choose object expiration rules carefully: blanket expiration
  of `inputs/` can delete inputs of still-active jobs. An `outputs/` rule longer
  than service retention can clean objects orphaned before a database commit.
- Alert on cleanup-deferred log events, growing pending deletion counts, old active
  jobs, bucket growth, and dispatcher failures. The worker must be running for
  periodic cleanup to occur.

Webhook destinations must be operator-registered exact matches. Enforce an egress
firewall that blocks private/link-local/metadata destinations and DNS rebinding;
application allowlisting alone is not that boundary. Redirects are refused.
