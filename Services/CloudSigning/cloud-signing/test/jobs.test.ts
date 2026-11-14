import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { submitJobs, APIError, type Submission } from '../src/jobs.js';
import type { Infrastructure } from '../src/infrastructure.js';
import { unseal } from '../src/security.js';

const request: Submission = { ipaId: 'ipa-a', p12Id: 'p12-a', provisionId: 'provision-a', password: 'sensitive-test-value', idempotencyKey: 'idempotency-a' };
function database(options: { owned?: boolean; active?: number; prior?: Record<string, unknown> } = {}) {
  const calls: { sql: string; params: unknown[] }[] = [];
  let released = false;
  const client = {
    async query(sql: string, params: unknown[] = []) {
      calls.push({ sql, params });
      if (sql.includes('count(*)')) return { rows: [{ count: options.active ?? 0 }] };
      if (sql.includes('idempotency_key=$2')) return { rows: options.prior ? [options.prior] : [], rowCount: options.prior ? 1 : 0 };
      if (sql.includes('SELECT id, kind FROM assets')) return { rows: options.owned === false ? [] : [{ id: 'ipa-a', kind: 'ipa' }, { id: 'p12-a', kind: 'p12' }, { id: 'provision-a', kind: 'provision' }] };
      return { rows: [], rowCount: 1 };
    },
    release() { released = true; },
  };
  return { calls, released: () => released, infra: { pool: { connect: async () => client } } as unknown as Infrastructure };
}
test('submission commits a password envelope and audit event atomically', async () => {
  const db = database(); const key = randomBytes(32);
  const [job] = await submitJobs(db.infra, key, 'tenant-a', 'sign', [request]);
  assert.ok(job?.id); assert.equal(job?.state, 'queued');
  const insert = db.calls.find(call => call.sql.startsWith('INSERT INTO jobs'))!;
  assert.equal(insert.params[1], 'tenant-a');
  assert.equal(unseal(insert.params[8] as string, key, job!.id), request.password);
  assert.ok(!JSON.stringify(db.calls).includes(request.password));
  assert.ok(db.calls.some(call => call.sql.includes('audit_logs')));
  assert.equal(db.calls.at(-1)?.sql, 'COMMIT'); assert.ok(db.released());
});
test('cross-tenant or wrong-kind assets roll back the entire submission', async () => {
  const db = database({ owned: false });
  await assert.rejects(submitJobs(db.infra, randomBytes(32), 'tenant-b', 'sign', [request]), (error: unknown) => error instanceof APIError && error.statusCode === 404);
  assert.equal(db.calls.at(-1)?.sql, 'ROLLBACK');
  assert.equal(db.calls.some(call => call.sql.startsWith('INSERT INTO jobs')), false);
  assert.ok(db.released());
});
test('active quotas and conflicting idempotency keys do not create duplicate work', async () => {
  const full = database({ active: 100 });
  await assert.rejects(submitJobs(full.infra, randomBytes(32), 'tenant', 'sign', [request]), (error: unknown) => error instanceof APIError && error.statusCode === 429);
  const conflict = database({ prior: { id: 'existing', state: 'queued', request_hash: 'different' } });
  await assert.rejects(submitJobs(conflict.infra, randomBytes(32), 'tenant', 'sign', [request]), (error: unknown) => error instanceof APIError && error.statusCode === 409);
  assert.equal(conflict.calls.at(-1)?.sql, 'ROLLBACK');
});
