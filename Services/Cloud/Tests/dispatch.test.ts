import test from 'node:test';
import assert from 'node:assert/strict';
import { PendingJobDispatcher } from '../Signing/JobQueue/dispatch.js';
import type { Infrastructure } from '../VexSign/Storage/infrastructure.js';

function id(index: number) { return `00000000-0000-4000-8000-${index.toString(16).padStart(12, '0')}`; }
function fixture(count: number) {
  const ids = Array.from({ length: count }, (_, index) => id(index + 1));
  const queue = new Map<string, 'waiting' | 'failed'>();
  const added: string[] = []; const marked: string[] = []; const cursors: (string | null)[] = [];
  const resets: string[] = [];
  const running = new Set<string>();
  let failNextAdd = false;
  const infra = {
    pool: { async query(sql: string, params: unknown[] = []) {
      if (sql.startsWith('SELECT id, state FROM jobs')) {
        const cursor = params[0] as string | null;
        cursors.push(cursor);
        return { rows: ids.filter(value => !cursor || value > cursor).slice(0, 100)
          .map(value => ({ id: value, state: running.has(value) ? 'running' : 'queued' })) };
      }
      if (sql.startsWith('UPDATE jobs SET state=\'queued\'')) {
        resets.push(params[0] as string); running.delete(params[0] as string);
        return { rows: [], rowCount: 1 };
      }
      if (sql.startsWith('UPDATE jobs SET published_at')) marked.push(params[0] as string);
      return { rows: [], rowCount: 0 };
    } },
    queue: {
      async getJob(key: string) {
        const state = queue.get(key);
        return state ? { getState: async () => state } : undefined;
      },
      async add(_name: string, body: { id: string }, options: { jobId: string }) {
        if (failNextAdd) { failNextAdd = false; throw new Error('redis unavailable'); }
        assert.equal(options.jobId, body.id);
        queue.set(body.id, 'waiting'); added.push(body.id);
      },
    },
  } as unknown as Infrastructure;
  return { infra, ids, queue, added, marked, cursors, resets, running,
    failAdd: () => { failNextAdd = true; } };
}

test('published jobs cannot starve later pages and the scan wraps for Redis recovery', async () => {
  const f = fixture(205); const dispatcher = new PendingJobDispatcher();
  for (const key of f.ids.slice(0, 100)) f.queue.set(key, 'waiting');
  const failed: string[] = [];
  await dispatcher.dispatch(f.infra, async key => { failed.push(key); });
  assert.equal(f.added.length, 0);
  await dispatcher.dispatch(f.infra, async key => { failed.push(key); });
  await dispatcher.dispatch(f.infra, async key => { failed.push(key); });
  assert.deepEqual(f.added, f.ids.slice(100));
  assert.deepEqual(f.marked, f.ids.slice(100));
  assert.equal(failed.length, 0);
  const lost = f.ids[0]!; f.queue.delete(lost);
  await dispatcher.dispatch(f.infra, async key => { failed.push(key); });
  assert.equal(f.queue.get(lost), 'waiting');
  assert.equal(f.cursors.at(-1), null);
});

test('a transient publish error retries the same page', async () => {
  const f = fixture(101); const dispatcher = new PendingJobDispatcher();
  f.failAdd();
  await assert.rejects(dispatcher.dispatch(f.infra, async () => {}), /redis unavailable/);
  await dispatcher.dispatch(f.infra, async () => {});
  assert.deepEqual(f.cursors, [null, null]);
  assert.equal(f.added.length, 100);
  await dispatcher.dispatch(f.infra, async () => {});
  assert.equal(f.added.length, 101);
});

test('failed Redis jobs are handed to the terminal-state writer', async () => {
  const f = fixture(1); const dispatcher = new PendingJobDispatcher();
  f.queue.set(f.ids[0]!, 'failed');
  const failed: string[] = [];
  await dispatcher.dispatch(f.infra, async key => { failed.push(key); });
  assert.deepEqual(failed, [f.ids[0]]);
  assert.deepEqual(f.added, []);
});

test('an abandoned claim is reset so a job whose worker died can run again', async () => {
  const f = fixture(1); const dispatcher = new PendingJobDispatcher();
  // The worker claimed the row, then died before finishing; Redis lost its job too.
  f.running.add(f.ids[0]!);
  await dispatcher.dispatch(f.infra, async () => {});
  // Without the reset the worker's claim guard (`state='queued'`) could never win again and the
  // job would sit in `running` forever.
  assert.deepEqual(f.resets, [f.ids[0]]);
  assert.deepEqual(f.added, [f.ids[0]]);
});

test('a queued job is never rewritten by the dispatcher', async () => {
  const f = fixture(2); const dispatcher = new PendingJobDispatcher();
  await dispatcher.dispatch(f.infra, async () => {});
  assert.deepEqual(f.resets, []);
});
