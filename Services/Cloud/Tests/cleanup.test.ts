import test from 'node:test';
import assert from 'node:assert/strict';
import { purgeUnreferencedJobInputs, sweepInputs, sweepOutputs, type WorkerDeps } from '../Signing/Worker/processor.js';

test('input deletion commits intent before touching S3 and leaves failed deletes retryable', async () => {
  const calls: string[] = [];
  const deps = { config: { S3_BUCKET: 'test' }, infra: {
    pool: {
      async connect() { return { async query(sql: string) {
        calls.push(sql);
        return { rows: sql.includes('RETURNING id,object_key') ? [{ id: 'a', object_key: 'inputs/a' }] : [] };
      }, release() { calls.push('release'); } }; },
      async query(sql: string) { calls.push(sql); return { rows: [] }; },
    },
    s3: { async send() { calls.push('delete'); throw new Error('offline'); } },
  } } as unknown as WorkerDeps;
  await purgeUnreferencedJobInputs(deps, 'owner', ['a']);
  assert.ok(calls.some(sql => sql.includes('pg_advisory_xact_lock')));
  assert.ok(calls.indexOf('COMMIT') < calls.indexOf('delete'));
  assert.ok(!calls.some(sql => sql.startsWith('UPDATE assets SET purged_at')));
});

test('input sweep selects pending retries and stale uploads but excludes active references', async () => {
  let query = '';
  const deps = { infra: { pool: { async query(sql: string) { query = sql; return { rows: [] }; } } } } as unknown as WorkerDeps;
  await sweepInputs(deps);
  assert.match(query, /deletion_requested_at IS NOT NULL/);
  assert.match(query, /24 hours/);
  assert.match(query, /NOT EXISTS/);
  assert.match(query, /LIMIT 100/);
});

test('output expiry retries failed S3 deletion before clearing the database key', async () => {
  let fail = true; const updates: string[] = [];
  const deps = { config: { S3_BUCKET: 'test' }, infra: {
    pool: { async query(sql: string) {
      if (sql.startsWith('SELECT')) { assert.match(sql, /7 days/); return { rows: [{ id: 'a', output_key: 'outputs/a.ipa' }] }; }
      updates.push(sql); return { rows: [] };
    } },
    s3: { async send() { if (fail) throw new Error('offline'); } },
  } } as unknown as WorkerDeps;
  await sweepOutputs(deps); assert.equal(updates.length, 0);
  fail = false; await sweepOutputs(deps); assert.equal(updates.length, 1);
});
