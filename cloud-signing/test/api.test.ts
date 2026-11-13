import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, createSign, randomBytes } from 'node:crypto';
import { buildApp } from '../src/app.js';
import type { Config } from '../src/config.js';
import type { Infrastructure } from '../src/infrastructure.js';
import { capability } from '../src/security.js';

const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const encryptionKey = randomBytes(32).toString('hex');
const config: Config = {
  DATABASE_URL: 'unused', REDIS_URL: 'redis://unused', S3_ENDPOINT: 'https://storage.test', S3_REGION: 'test', S3_BUCKET: 'test',
  PUBLIC_ORIGIN: 'https://install.test', JWT_PUBLIC_KEY_FILE: 'unused', JWT_ISSUER: 'https://auth.test', JWT_AUDIENCE: 'signing',
  jwtPublicKey: publicKey.export({ type: 'spki', format: 'pem' }).toString(), ENCRYPTION_KEY: encryptionKey,
  PORT: 8080, SIGNER_EXECUTABLE: '/unused', SIGNING_CONCURRENCY: 1, WEBHOOK_ALLOWLIST: '', TRUSTED_PROXIES: '',
};
function token(sub: string, overrides: Record<string, unknown> = {}) {
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({ sub, iss: config.JWT_ISSUER, aud: config.JWT_AUDIENCE, exp: Math.floor(Date.now() / 1000) + 600, iat: Math.floor(Date.now() / 1000), scope: 'signing:write', ...overrides })).toString('base64url');
  const body = `${header}.${claims}`;
  return `${body}.${createSign('RSA-SHA256').update(body).sign(privateKey).toString('base64url')}`;
}
// Fastify's Redis rate-limit store interface; these are isolated HTTP contract tests,
// not a substitute for the PostgreSQL/Redis/S3 deployment integration suite.
function fakeInfra() {
  const calls: { sql: string; values: unknown[] }[] = [];
  const redis = {
    defineCommand() {},
    rateLimit(...args: unknown[]) { (args.at(-1) as Function)(null, [1, 60_000]); },
    eval: async () => 1, ping: async () => 'PONG',
  };
  return { calls, infra: { redis, pool: { query: async (sql: string, values: unknown[] = []) => {
    calls.push({ sql, values }); return { rows: [], rowCount: 0 };
  } } } as unknown as Infrastructure };
}

test('API rejects missing JWT, wrong audience, missing scope, and expired tokens before SQL', async () => {
  const fake = fakeInfra(); const app = await buildApp(config, fake.infra);
  try {
    for (const bearer of [undefined, token('a', { aud: 'wrong' }), token('a', { scope: '' }), token('a', { exp: 1 })]) {
      const response = await app.inject({ method: 'GET', url: '/api/queue', headers: bearer ? { authorization: `Bearer ${bearer}` } : {} });
      assert.ok([401, 403].includes(response.statusCode), response.body);
    }
    assert.equal(fake.calls.length, 0);
  } finally { await app.close(); }
});
test('tenant identity scopes job status queries; guessed job IDs do not leak records', async () => {
  const fake = fakeInfra(); const app = await buildApp(config, fake.infra);
  try {
    const response = await app.inject({ method: 'GET', url: '/api/jobs/01234567-89ab-4def-8123-456789abcdef', headers: { authorization: `Bearer ${token('owner-a')}` } });
    assert.equal(response.statusCode, 404);
    assert.equal(fake.calls[0]?.values[1], 'owner-a');
    assert.ok(fake.calls[0]?.sql.includes('owner=$2'));
  } finally { await app.close(); }
});
test('OTA fails closed without valid resource-specific capability', async () => {
  const fake = fakeInfra(); const app = await buildApp(config, fake.infra);
  const id = '01234567-89ab-4def-8123-456789abcdef';
  try {
    const bad = capability('another-id', Math.floor(Date.now() / 1000) + 60, Buffer.from(encryptionKey, 'hex'));
    const response = await app.inject({ method: 'GET', url: `/manifest/${id}?token=${bad}` });
    assert.equal(response.statusCode, 404); assert.equal(fake.calls.length, 0);
    assert.ok(response.headers['content-security-policy']?.includes("frame-ancestors 'none'"));
  } finally { await app.close(); }
});

test('job status returns the documented view, not the raw row', async () => {
  const id = '01234567-89ab-4def-8123-456789abcdef';
  const createdAt = new Date('2026-01-02T03:04:05.000Z');
  const finishedAt = new Date('2026-01-02T03:05:05.000Z');
  const rowsFor = (row: Record<string, unknown>) => ({
    redis: { defineCommand() {}, rateLimit(...args: unknown[]) { (args.at(-1) as Function)(null, [1, 60_000]); }, eval: async () => 1, ping: async () => 'PONG' },
    pool: { query: async () => ({ rows: [row], rowCount: 1 }) },
  }) as unknown as Infrastructure;

  const completed = await buildApp(config, rowsFor({
    id, kind: 'sign', state: 'completed',
    result: { name: 'App', bundleIdentifier: 'com.example.app', version: '1.0', changelog: '', screenshotURLs: [] },
    error_code: null, output_sha256: 'a'.repeat(64), created_at: createdAt, finished_at: finishedAt,
  }));
  try {
    const response = await completed.inject({ method: 'GET', url: `/api/jobs/${id}`, headers: { authorization: `Bearer ${token('owner-a')}` } });
    assert.equal(response.statusCode, 200, response.body);
    const body = response.json();
    // Exactly the documented fields: no owner, no sealed password, no object keys.
    assert.deepEqual(Object.keys(body).sort(), ['created_at', 'error_code', 'finished_at', 'id', 'installURL', 'kind', 'output_sha256', 'result', 'state']);
    assert.equal(body.created_at, '2026-01-02T03:04:05.000Z');
    assert.equal(body.state, 'completed');
    assert.ok(String(body.installURL).startsWith('https://install.test/install/'));
    assert.ok(String(body.installURL).includes('?token='));
  } finally { await completed.close(); }

  const inspect = await buildApp(config, rowsFor({
    id, kind: 'check-cert', state: 'completed', result: { status: 'good' },
    error_code: null, output_sha256: null, created_at: createdAt, finished_at: finishedAt,
  }));
  try {
    const response = await inspect.inject({ method: 'GET', url: `/api/jobs/${id}`, headers: { authorization: `Bearer ${token('owner-a')}` } });
    const body = response.json();
    // A certificate check has no artifact, so it must not advertise an install link.
    assert.equal(body.installURL, undefined);
    assert.equal(body.output_sha256, null);
  } finally { await inspect.close(); }
});

test('a job row that drifts from the contract fails instead of reaching the client', async () => {
  const id = '01234567-89ab-4def-8123-456789abcdef';
  const app = await buildApp(config, {
    redis: { defineCommand() {}, rateLimit(...args: unknown[]) { (args.at(-1) as Function)(null, [1, 60_000]); }, eval: async () => 1, ping: async () => 'PONG' },
    pool: { query: async () => ({ rows: [{ id, kind: 'sign', state: 'completed', result: null, error_code: null, created_at: new Date(), finished_at: null, owner: 'someone-else' }], rowCount: 1 }) },
  } as unknown as Infrastructure);
  try {
    const response = await app.inject({ method: 'GET', url: `/api/jobs/${id}`, headers: { authorization: `Bearer ${token('owner-a')}` } });
    // Fails closed: the schema rejects it rather than leaking an unexpected field or shape.
    assert.equal(response.statusCode, 500);
    assert.equal(response.json().error, 'Service unavailable');
  } finally { await app.close(); }
});
