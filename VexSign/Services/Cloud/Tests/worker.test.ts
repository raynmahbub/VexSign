import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { Readable } from 'node:stream';
import { mkdtemp, writeFile, rm, stat, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Job } from 'bullmq';
import type { Config } from '../Configuration/config.js';
import type { Infrastructure } from '../Storage/infrastructure.js';
import { seal } from '../Security/security.js';
import { deliverWebhooks, failureCode, fetchAsset, finish, hashingStream, processJob, type WorkerDeps } from '../Signing/Worker/processor.js';

const key = randomBytes(32);
const config: Config = {
  DATABASE_URL: 'unused', REDIS_URL: 'redis://unused', S3_ENDPOINT: 'https://storage.test', S3_REGION: 'test', S3_BUCKET: 'test',
  PUBLIC_ORIGIN: 'https://install.test', JWT_PUBLIC_KEY_FILE: 'unused', JWT_ISSUER: 'https://auth.test', JWT_AUDIENCE: 'signing',
  jwtPublicKey: 'unused', ENCRYPTION_KEY: key.toString('hex'),
  PORT: 8080, SIGNER_EXECUTABLE: '/unused', SIGNING_CONCURRENCY: 1, WEBHOOK_ALLOWLIST: '', TRUSTED_PROXIES: '',
};
const jobId = '01234567-89ab-4def-8123-456789abcdef';
function job(overrides: Partial<Job<{ id: string }>> = {}): Job<{ id: string }> {
  return { data: { id: jobId }, attemptsMade: 0, opts: { attempts: 1 }, ...overrides } as unknown as Job<{ id: string }>;
}
async function scratch<T>(run: (dir: string) => Promise<T>): Promise<T> {
  const dir = await mkdtemp(join(tmpdir(), 'vexsign-worker-test-'));
  try { return await run(dir); } finally { await rm(dir, { recursive: true, force: true }); }
}
/** Collects what the worker logs, so a test can assert on diagnostics without printing them. */
function captureLog(): { lines: string[]; restore: () => void } {
  const lines: string[] = []; const original = console.error;
  console.error = (...args: unknown[]) => { lines.push(args.map(String).join(' ')); };
  return { lines, restore: () => { console.error = original; } };
}

test('a failure reason is logged as a sentinel or a type name, never as a message', () => {
  // These five are fixed strings this service defines, so they are safe to persist and log.
  for (const sentinel of ['ASSET_MISSING', 'INTEGRITY_ERROR', 'INVALID_OUTPUT', 'SIGNER_FAILED', 'INVALID_SIGNER_RESULT']) {
    assert.equal(failureCode(new Error(sentinel)), sentinel);
  }
  // Everything else may interpolate a DSN, an object key or a path, so only its type survives.
  class DriverError extends Error { constructor(message: string) { super(message); this.name = 'DriverError'; } }
  assert.equal(failureCode(new DriverError('postgres://user:hunter2@db.internal:5432/signing')), 'DriverError');
  assert.equal(failureCode(new Error('AccessDenied on s3://test/inputs/abc')), 'Error');
  assert.equal(failureCode('not an error'), 'UnknownError');
  assert.equal(failureCode(undefined), 'UnknownError');
  for (const value of ['postgres://user:hunter2@db', 's3://test/inputs/abc', '/tmp/vexsign-job-1/identity.p12']) {
    assert.ok(!failureCode(new Error(value)).includes(value), `leaked ${value}`);
  }
});

test('the artifact hash covers exactly the bytes the uploader consumes', async () => {
  const payload = Buffer.concat([randomBytes(1024), Buffer.from('PK\u0003\u0004 tail'), randomBytes(4096)]);
  const artifact = hashingStream(Readable.from([payload.subarray(0, 2048), payload.subarray(2048)]));
  const seen: Buffer[] = [];
  for await (const chunk of artifact.body) seen.push(Buffer.from(chunk));
  assert.equal(Buffer.concat(seen).toString('hex'), payload.toString('hex'), 'bytes must pass through unchanged');
  assert.equal(artifact.hex(), createHash('sha256').update(payload).digest('hex'));
});

test('an unreadable artifact fails the job instead of stalling the upload', async () => {
  const source = new Readable({ read() {} });
  const artifact = hashingStream(source);
  const consumed = new Promise((resolve, reject) => {
    artifact.body.on('error', reject);
    artifact.body.on('end', resolve);
    artifact.body.resume();
  });
  // `.pipe` would leave the destination waiting forever; the source error has to reach it.
  source.destroy(new Error('ENOSPC: no space left on device'));
  await assert.rejects(consumed, /ENOSPC/);
});

function assetDeps(asset: { object_key: string; sha256: string; bytes: number } | null, body: Buffer | null): WorkerDeps {
  const infra = {
    pool: { query: async () => ({ rows: asset ? [asset] : [], rowCount: asset ? 1 : 0 }) },
    s3: { send: async () => ({ Body: body === null ? undefined : Readable.from([body]) }) },
  } as unknown as Infrastructure;
  return { config, infra, key };
}

test('an inbound asset is verified against its recorded size and digest', async () => {
  const body = Buffer.concat([randomBytes(2048), Buffer.from('identity')]);
  const recorded = { object_key: 'inputs/abc', sha256: createHash('sha256').update(body).digest('hex'), bytes: body.length };
  await scratch(async dir => {
    const destination = join(dir, 'identity.p12');
    await fetchAsset(assetDeps(recorded, body), 'asset-1', 'owner-a', destination, 'p12');
    assert.equal((await readFile(destination)).toString('hex'), body.toString('hex'));
    // 0600: the plaintext p12 must not be readable by another user on a shared worker host.
    assert.equal((await stat(destination)).mode & 0o777, 0o600);
  });
});

test('a truncated, oversized, missing or already-present asset is refused', async () => {
  const body = Buffer.from('a real p12 payload');
  const digest = createHash('sha256').update(body).digest('hex');
  const cases: [string, { object_key: string; sha256: string; bytes: number } | null, Buffer | null, RegExp][] = [
    ['no row', null, body, /ASSET_MISSING/],
    ['no object', { object_key: 'inputs/abc', sha256: digest, bytes: body.length }, null, /ASSET_MISSING/],
    ['digest mismatch', { object_key: 'inputs/abc', sha256: 'f'.repeat(64), bytes: body.length }, body, /INTEGRITY_ERROR/],
    ['more bytes than recorded', { object_key: 'inputs/abc', sha256: digest, bytes: body.length - 1 }, body, /INTEGRITY_ERROR/],
    ['fewer bytes than recorded', { object_key: 'inputs/abc', sha256: digest, bytes: body.length + 1 }, body, /INTEGRITY_ERROR/],
  ];
  for (const [name, asset, payload, expected] of cases) {
    await scratch(async dir => {
      const destination = join(dir, 'identity.p12');
      await assert.rejects(fetchAsset(assetDeps(asset, payload), 'asset-1', 'owner-a', destination, 'p12'), expected, name);
    });
  }
  // `wx` means a directory left behind by a crashed worker can never be reused or appended to.
  await scratch(async dir => {
    const destination = join(dir, 'identity.p12');
    await writeFile(destination, 'stale bytes from a crashed run');
    await assert.rejects(
      fetchAsset(assetDeps({ object_key: 'inputs/abc', sha256: digest, bytes: body.length }, body), 'asset-1', 'owner-a', destination, 'p12'),
      /EEXIST/,
    );
  });
});

function routedDeps(routes: { job: Record<string, unknown> | null; asset: Record<string, unknown> | null }) {
  const statements: { sql: string; values: unknown[] }[] = [];
  const infra = {
    pool: {
      query: async (sql: string, values: unknown[] = []) => {
        if (sql.startsWith('SELECT * FROM jobs')) return { rows: routes.job ? [routes.job] : [], rowCount: routes.job ? 1 : 0 };
        if (sql.startsWith('SELECT object_key')) return { rows: routes.asset ? [routes.asset] : [], rowCount: routes.asset ? 1 : 0 };
        return { rows: [], rowCount: 0 };
      },
      connect: async () => ({
        query: async (sql: string, values: unknown[] = []) => {
          statements.push({ sql, values });
          if (sql.startsWith('UPDATE jobs')) return { rows: [{ owner: 'owner-a', webhook: null }], rowCount: 1 };
          return { rows: [], rowCount: 0 };
        },
        release() {},
      }),
    },
  } as unknown as Infrastructure;
  return { deps: { config, infra, key } as WorkerDeps, statements };
}

test('a job already in a terminal state is left alone', async () => {
  for (const state of ['completed', 'failed']) {
    const { deps, statements } = routedDeps({ job: { id: jobId, state }, asset: null });
    await processJob(deps, job());
    // Re-running a finished job must not rewrite its result, re-deliver its webhook or resurrect
    // the password envelope that the terminal write cleared.
    assert.equal(statements.length, 0, `${state}: must not write`);
  }
});

test('a failed job records and logs the specific reason, not a generic one', async () => {
  const sealed = seal('correct horse battery staple', key, jobId);
  // The p12 row exists but the provisioning profile does not, so the job dies in `fetchAsset`.
  const { deps, statements } = routedDeps({
    job: { id: jobId, state: 'queued', kind: 'sign', owner: 'owner-a', sealed_password: sealed,
      p12_id: 'p12', provision_id: 'provision', ipa_id: 'ipa' },
    asset: null,
  });
  const log = captureLog();
  try {
    await assert.rejects(processJob(deps, job()), /SIGNING_FAILED/);
  } finally { log.restore(); }

  const terminal = statements.find(s => s.sql.startsWith('UPDATE jobs SET state=$2'));
  assert.ok(terminal, 'the job must reach a terminal state');
  // $6 is error_code: the operator sees which step failed instead of one blanket SIGNING_FAILED.
  assert.equal(terminal.values[5], 'ASSET_MISSING');
  assert.equal(terminal.values[1], 'failed');
  assert.ok(log.lines.some(line => line.includes(jobId) && line.includes('ASSET_MISSING')), `expected a diagnostic, got: ${JSON.stringify(log.lines)}`);
  assert.ok(!log.lines.some(line => line.includes('correct horse')), 'the password must never be logged');
  // The plaintext secret is cleared on the way to the terminal state.
  assert.match(terminal.sql, /sealed_password=NULL/);
});

test('a webhook failure is logged without the endpoint URL', async () => {
  const url = 'https://hooks.private.example/signing';
  const rows = [{ job_id: jobId, url, payload: { jobId, state: 'completed' } }];
  function webhookDeps(allowlist: string) {
    const delivered: string[] = [];
    const infra = {
      pool: { query: async (sql: string) => {
        if (sql.startsWith('UPDATE webhook_deliveries SET attempts')) return { rows, rowCount: rows.length };
        delivered.push(sql); return { rows: [], rowCount: 0 };
      } },
    } as unknown as Infrastructure;
    return { deps: { config: { ...config, WEBHOOK_ALLOWLIST: allowlist }, infra, key } as WorkerDeps, delivered };
  }

  // An unregistered endpoint is skipped before any request is made.
  const blocked = webhookDeps('');
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (async () => { calls += 1; throw new Error(`connect ECONNREFUSED ${url}`); }) as unknown as typeof fetch;
  const log = captureLog();
  try {
    await deliverWebhooks(blocked.deps);
    assert.equal(calls, 0, 'an unregistered webhook must not be dialled');

    // A registered endpoint that fails: the lease retries, and the log names the job, not the URL.
    const allowed = webhookDeps(url);
    await deliverWebhooks(allowed.deps);
    assert.equal(calls, 1);
    assert.equal(allowed.delivered.length, 0, 'a failed delivery must not be marked delivered');
  } finally { log.restore(); globalThis.fetch = originalFetch; }

  assert.ok(log.lines.some(line => line.includes(jobId)), `expected the job id in: ${JSON.stringify(log.lines)}`);
  assert.ok(!log.lines.some(line => line.includes('hooks.private.example')), `endpoint URL leaked: ${JSON.stringify(log.lines)}`);
});

test('a completed job clears the password envelope and records the artifact hash', async () => {
  const statements: { sql: string; values: unknown[] }[] = [];
  const infra = {
    pool: {
      connect: async () => ({
        query: async (sql: string, values: unknown[] = []) => { statements.push({ sql, values }); return { rows: [], rowCount: 0 }; },
        release() {},
      }),
    },
  } as unknown as Infrastructure;
  const deps = { config, infra, key } as WorkerDeps;
  await finish(deps, jobId, 'completed', { name: 'App' }, `outputs/${jobId}.ipa`, 'a'.repeat(64));
  const update = statements.find(s => s.sql.startsWith('UPDATE jobs'));
  assert.ok(update);
  assert.equal(update.values[5], null, 'a completed job carries no error code');
  assert.equal(update.values[4], 'a'.repeat(64));
  assert.match(update.sql, /sealed_password=NULL/);
  // Default code keeps the historical value when a caller does not supply one.
  statements.length = 0;
  await finish(deps, jobId, 'failed', null, null, null);
  assert.equal(statements.find(s => s.sql.startsWith('UPDATE jobs'))?.values[5], 'SIGNING_FAILED');
});
