import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import pg from 'pg';
import type { Infrastructure } from '../Storage/infrastructure.js';
import type { WorkerDeps } from '../Signing/Worker/processor.js';
import { purgeUnreferencedJobInputs } from '../Signing/Worker/processor.js';
import { APIError, submitJobs } from '../Signing/JobQueue/jobs.js';

// Dedicated disposable database only; each run isolates its tables in a new schema.
test('PostgreSQL: deletion intent rejects racing submissions and survives S3 failure', {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const schema = `test_${randomUUID().replaceAll('-', '')}`;
  const admin = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
  await admin.query(`CREATE SCHEMA ${schema}`);
  const pool = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL, options: `-c search_path=${schema}`, max: 4 });
  try {
    for (const file of ['001_initial.sql', '002_indexes_and_retention.sql', '003_input_cleanup.sql']) {
      await pool.query(await readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8'));
    }
    const ids = [randomUUID(), randomUUID(), randomUUID()];
    for (const [i, kind] of ['ipa', 'p12', 'provision'].entries()) {
      await pool.query('INSERT INTO assets(id,owner,kind,object_key,sha256,bytes) VALUES($1,$2,$3,$4,$5,1)',
        [ids[i], 'tenant', kind, `inputs/${ids[i]}`, 'a'.repeat(64)]);
    }
    let deletionStarted!: () => void;
    const started = new Promise<void>(resolve => { deletionStarted = resolve; });
    let releaseDeletion!: () => void;
    const gate = new Promise<void>(resolve => { releaseDeletion = resolve; });
    const infra = { pool, s3: { async send() { deletionStarted(); await gate; throw new Error('unavailable'); } } } as unknown as Infrastructure;
    const deps = { infra, config: { S3_BUCKET: 'test' } } as WorkerDeps;
    const cleanup = purgeUnreferencedJobInputs(deps, 'tenant', [ids[1]!]);
    await started;
    try {
      await assert.rejects(submitJobs(infra, randomBytes(32), 'tenant', 'sign', [{
        ipaId: ids[0], p12Id: ids[1]!, provisionId: ids[2]!, password: 'test', idempotencyKey: randomUUID(),
      }]), (error: unknown) => error instanceof APIError && error.statusCode === 404);
    } finally { releaseDeletion(); await cleanup; }
    const row = (await pool.query('SELECT deletion_requested_at,purged_at FROM assets WHERE id=$1', [ids[1]])).rows[0];
    assert.ok(row.deletion_requested_at);
    assert.equal(row.purged_at, null);
    let deleted = 0;
    deps.infra.s3 = { async send() { deleted++; return {}; } } as unknown as Infrastructure['s3'];
    await purgeUnreferencedJobInputs(deps, 'tenant', [ids[1]!]);
    assert.equal(deleted, 1);
    assert.ok((await pool.query('SELECT purged_at FROM assets WHERE id=$1', [ids[1]])).rows[0].purged_at);
    // A queued reference protects every remaining input from cleanup.
    await pool.query('UPDATE assets SET deletion_requested_at=NULL,purged_at=NULL WHERE id=$1', [ids[1]]);
    await submitJobs(infra, randomBytes(32), 'tenant', 'sign', [{
      ipaId: ids[0], p12Id: ids[1]!, provisionId: ids[2]!, password: 'test', idempotencyKey: randomUUID(),
    }]);
    await purgeUnreferencedJobInputs(deps, 'tenant', ids);
    assert.equal(deleted, 1);
  } finally {
    await pool.end();
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  }
});

test('Redis: terminal no-op delivery can be replaced and consumed again', {
  skip: !process.env.TEST_REDIS_URL,
}, async () => {
  const { Redis } = await import('ioredis');
  const { Queue, Worker, QueueEvents } = await import('bullmq');
  const { PendingJobDispatcher } = await import('../Signing/JobQueue/dispatch.js');
  const connection = new Redis(process.env.TEST_REDIS_URL!, { maxRetriesPerRequest: null });
  const name = `recovery-${randomUUID()}`;
  const queue = new Queue(name, { connection });
  const events = new QueueEvents(name, { connection });
  let runs = 0;
  const worker = new Worker(name, async () => { runs++; }, { connection });
  try {
    await events.waitUntilReady(); await worker.waitUntilReady();
    const id = randomUUID();
    const first = await queue.add('sign', { id }, { jobId: id });
    await first.waitUntilFinished(events, 10_000);
    const infra = { queue, pool: { async query(sql: string) {
      if (sql.startsWith('SELECT')) return { rows: [{ id, state: 'running' }] };
      return { rows: [], rowCount: 1 }; // expired PostgreSQL claim
    } } } as unknown as Infrastructure;
    await new PendingJobDispatcher().dispatch(infra, async () => assert.fail('not failed'));
    const replacement = await queue.getJob(id);
    assert.ok(replacement);
    await replacement.waitUntilFinished(events, 10_000);
    assert.equal(runs, 2);
  } finally {
    await worker.close(); await events.close(); await queue.obliterate({ force: true });
    await queue.close(); await connection.quit();
  }
});
