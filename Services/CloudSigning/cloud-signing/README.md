# VexSign Cloud Signing

An **additive, separately deployed service**, not a replacement for `../Services/API/server/` (the existing premium API). Node 22, TypeScript, Fastify, PostgreSQL, Redis/BullMQ, private S3-compatible storage.

**Release status:** type-checked and unit/HTTP-contract tested. Real signing, OCSP, PostgreSQL/Redis/S3 integration, archive sandboxing and device OTA acceptance must pass deployment qualification. A signing engine is **not bundled**. The worker fails a job if the configured engine is absent or returns an invalid receipt; it never reports an unsigned input as a signed output.

## Run

```sh
npm ci
npm run check
npm test
npm run build
npm run contracts           # regenerate openapi.json
# Supply deployment secrets through your secret manager, then:
npm run migrate             # transactional, advisory-locked schema migration
npm start                   # HTTP API, binds 0.0.0.0:8080
# Separate process/container, same PostgreSQL/Redis/bucket/key configuration:
npm run worker
```

The Dockerfile builds the API or worker image; override the command with `node dist/src/worker.js` for workers. Mount your engine sandbox launcher read-only. Do not expose worker containers publicly.

## Configuration

| Variable | Requirement |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection, TLS in deployment; dedicated least-privilege role |
| `REDIS_URL` | Redis connection; TLS, authentication, AOF persistence and `noeviction` in deployment |
| `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION` | Private HTTPS endpoint; region defaults to `us-east-1` |
| AWS credential provider chain | Workload identity preferred; never ship credentials to the client |
| `S3_KMS_KEY_ID` | Optional KMS key. SSE-KMS when set, SSE-S3 AES256 otherwise; provider must support requested encryption |
| `PUBLIC_ORIGIN` | Publicly trusted bare HTTPS origin, e.g. `https://signing.example.com` |
| `JWT_PUBLIC_KEY_FILE` | Mounted RSA public key, not a shared JWT signing secret |
| `JWT_ISSUER`, `JWT_AUDIENCE` | Exact permitted claims from your identity provider |
| `ENCRYPTION_KEY` | 32 random bytes as 64 hex characters, provisioned by a secret manager |
| `SIGNER_EXECUTABLE` | Absolute path to the administrator-managed **sandbox launcher**, required |
| `SIGNING_CONCURRENCY` | 1–8, defaults to 2 |
| `PORT` | Defaults to 8080 |
| `TRUSTED_PROXIES` | Comma-separated known proxy IPs/CIDRs; unset means do not trust forwarded headers |
| `WEBHOOK_ALLOWLIST` | Comma-separated, exact, operator-approved HTTPS callback URLs; empty disables callbacks |

No configuration file with credentials is checked in. Key rotation must drain jobs encrypted with the old key before replacing it; OTA capabilities and webhook signing keys are HKDF-derived and also rotate. There is no automated multi-key rotation manager in this version.

## API and authorization

See [`openapi.json`](openapi.json) for the generated contract. Authenticate `/api/upload`, `/api/sign`, `/api/sign/batch`, `/api/check-cert`, `/api/jobs/:id`, and `/api/queue` with an RS256 bearer JWT containing `sub`, `iss`, `aud`, `iat`, `exp`, and space-delimited scope `signing:write`. Token lifetime is at most one hour. There is deliberately no password-login or token-minting endpoint; use your identity provider.

1. `POST /api/upload?kind=ipa|p12|provision`: exactly one multipart file. Returns `id`, `kind`, `bytes`, `sha256`. IPA limit 2 GiB; certificate/profile limit 10 MiB. Names supplied by clients never become filesystem/S3 paths. ZIP magic is a prefilter, **not** archive validation.
2. `POST /api/sign`: `{ipaId,p12Id,provisionId,password,webhook?}` and UUID `Idempotency-Key` header. Returns `202 {id,state}`.
3. `POST /api/sign/batch`: `{jobs:[{...signRequest,idempotencyKey}]}`, 1–20 items, atomic transaction. Conflicting reused keys return 409.
4. `POST /api/check-cert`: `{p12Id,provisionId,password,webhook?}`, UUID `Idempotency-Key`. Asynchronous; poll the job endpoint for the engine's certificate result.
5. `GET /api/jobs/:id`: only the owner sees status, result, and a fresh 24-hour `installURL` for successful signing jobs. The body is the `JobView` schema in `openapi.json` and is validated before it is sent — `{id, kind, state, result, error_code, output_sha256, created_at, finished_at, installURL?}`, snake_case because it mirrors the row. Until recently this shape existed only in prose, and the iOS client had guessed `{status, progress, step, downloadUrl, error}`; the route now returns a parsed `JobView`, so a renamed column fails a contract check instead of an app. `output_sha256` is the digest of the stored artifact (null until a signing job completes) and is what a client should compare a download against. A response that does not match the schema is a `500`, not the client's `400`: only the schema name is logged.
6. `GET /api/queue`: only this tenant's counts, not a public BullMQ dashboard.
7. `/install/:id`, `/manifest/:id`, `/download/:id`, and `/api/install/:id`, `/api/download/:id` aliases require a resource-scoped `?token=` capability. They do not require bearer headers because iOS's OTA client cannot attach them. Download redirects to a 120-second S3 URL; manifest uses the capability-protected stable download endpoint.

Every failure answers the `Error` schema `{error, requestId}`; `requestId` is the only handle that ties a user's report to a server log line, and the iOS client surfaces it. `POST /api/sign` requires an `Idempotency-Key` header: reuse the same UUID when retrying an ambiguous submission and the service returns the original job, or `409` if the body changed. The iOS client sends the token in `Authorization` only — the service ignores `x-api-key` and does not redact it, so a client that sent it there wrote its credential into this service's logs.

JWT authentication runs before multipart parsing. Limits apply per IP (Redis) and tenant. Ownership is checked before enqueue and protected by composite PostgreSQL foreign keys. Active jobs are limited to 100 per tenant. Object storage byte quotas, subscription billing and lifecycle cleanup are deployment responsibilities and must be configured before public access.

## Signer protocol v1 — mandatory integration boundary

The worker invokes the fixed executable without a shell, arguments, inherited cloud secrets or credentials in the environment. A single JSON object arrives on stdin:

```json
{
  "protocolVersion": 1,
  "kind": "sign",
  "directory": "/private-job-directory",
  "ipaPath": "/private-job-directory/input.ipa",
  "p12Path": "/private-job-directory/identity.p12",
  "provisionPath": "/private-job-directory/profile.mobileprovision",
  "outputPath": "/private-job-directory/signed.ipa",
  "password": "supplied-only-on-stdin"
}
```

The trusted adapter must:

- Use your licensed/approved Zsign/codesign implementation; no arbitrary commands from IPA metadata.
- Run with a separate unprivileged identity in a sandbox that sees **only this job directory**. No PostgreSQL, Redis, S3, API keys, host home directory or other tenants' files. Worker UID isolation alone is insufficient.
- Enforce CPU, memory, disk, decompressed-byte, archive-entry-count and process limits. Reject zip-slip, absolute paths, symlink/hardlink escapes and archive bombs **before extraction**. The Node ZIP prefilter does not do this.
- Validate P12/profile pairing, authenticated provisioning CMS, profile/device/bundle eligibility, entitlements and expiry. Preserve/sign nested extensions and frameworks. Verify the output signature independently before acknowledging success.
- Never put passwords in `zsign -p ...` argv or logs. Use a library binding or a private pipe-aware wrapper.
- Extract final bundle identifier, display name and version from the **signed output**, not a client request. Optionally supply HTTPS icon/screenshot URLs and changelog.
- For certificate checks, validate OCSP evidence against trusted issuers, enforce response validity/freshness, and return `unknown` when no positive evidence exists. Do not synthesize `good` from an HTTP success or an unrevoked local flag.

Write the artifact to `outputPath`, exit 0, and emit **only** this bounded JSON receipt on stdout:

```json
{
  "kind": "sign",
  "signatureVerified": true,
  "metadata": {
    "name": "Example",
    "bundleIdentifier": "com.example.app",
    "version": "1.0",
    "changelog": "",
    "screenshotURLs": []
  }
}
```

For `kind: "check-cert"`, omit `ipaPath` and return:

```json
{
  "kind": "check-cert",
  "certificate": {
    "status": "unknown",
    "checkedAt": "2026-09-19T00:00:00Z",
    "teamID": "TEAMID",
    "teamName": "Example",
    "expiresAt": "2027-09-19T00:00:00Z",
    "detail": "OCSP responder unavailable"
  }
}
```

These are protocol examples, **not fixtures used to simulate real signing**. The process group is killed after ten minutes or invalid/oversized output. The worker checks artifact type/size, verifies input hashes and computes the output hash. The receipt is an assertion from the operator-trusted engine, not cryptographic proof from the Node orchestration layer.

## Queue, recovery, webhooks

PostgreSQL is authoritative. Job creation, encrypted password and audit event are one transaction. The dispatcher repairs unpublished/Redis-lost jobs using stable BullMQ job IDs. Workers use renewable locks and bounded concurrency. Transient failures retry three times with exponential backoff; stalled work is recovered by BullMQ. Terminal state and webhook outbox commit together. Password envelopes are cleared on terminal completion/failure.

Webhooks contain `{jobId,state}`, not install capabilities or signing material. Up to eight deliveries, with persisted five-minute leases; delivery is at least once. Deduplicate `x-vexsign-event-id`. Authenticate `x-vexsign-signature` as HMAC-SHA256 of `timestamp + '.' + rawBody`, using the HKDF-derived webhook key (`salt=''`, `info='vexsign.webhook.v1:' + exactRegisteredURL`). Reject old timestamps and replayed event IDs. Provision that derived key to registered receivers through your secret manager; never distribute the master encryption key.

Exact URL allowlisting and redirect rejection are implemented. **Enforce egress DNS/IP policy** to block private, loopback, link-local, metadata and rebinding targets. This version does not implement in-process DNS pinning.

## Deployment release checklist

- TLS-terminating proxy: request timeouts/body limits, range/redirect support, no capability/password/access-token logging. Only configure actual proxy CIDRs. HTTP listens privately behind this proxy.
- Private bucket, no anonymous ACLs; encryption required, storage quota, lifecycle rules for `inputs/`, `outputs/` and unfinished multipart uploads. Keep output long enough for issued capabilities (at least 24 hours).
- Dedicated encrypted ephemeral volume for job files; cleanup on normal completion is implemented. After worker host crashes, purge orphan `vexsign-job-*` directories **only once no old worker process is alive**. Use pod-scoped ephemeral volumes rather than shared `/tmp` in production.
- Database backup/restore exercise, Redis restart/loss, duplicate submissions, revoked/wrong-password/mismatched cert, malicious archives, exhausted disk, S3 outages and rolling worker shutdown tests.
- Real iPhone OTA test over publicly trusted HTTPS, including device exclusions and certificate revocation. OTA does not bypass Apple's provisioning rules.
- No hard-coded load/performance claims: run your workload and tune concurrency and upload limits.

## Tests

`npm test` runs crypto, capability, markup, schema, engine-failure, JWT, ownership, idempotency, quota and transaction-boundary tests. HTTP and database unit tests use isolated fakes; they are **not** live PostgreSQL/Redis/S3/signing integration tests. `npm run build` emits the real API and worker. `npm audit` was clean at implementation time; CI rechecks dependencies.
