import type { Infrastructure } from '../../Storage/infrastructure.js';

/**
 * Scan pending PostgreSQL jobs in bounded, rotating UUID pages. Existing Redis
 * jobs must not occupy the first page forever: other tenants and unpublished
 * jobs still need service. Wrapping also rechecks published work after Redis loss.
 * The cursor advances only after a complete page, so a transient error retries it.
 */
export class PendingJobDispatcher {
  private cursor: string | null = null;

  async dispatch(infra: Infrastructure, onFailed: (id: string) => Promise<void>): Promise<void> {
    const pending = await infra.pool.query<{ id: string; state: string }>(
      "SELECT id, state FROM jobs WHERE state IN ('queued','running') AND ($1::uuid IS NULL OR id > $1::uuid) ORDER BY id LIMIT 100",
      [this.cursor],
    );
    for (const row of pending.rows) {
      const existing = await infra.queue.getJob(row.id);
      if (!existing) {
        // A `running` row with no Redis job means the attempt that held it is gone — the worker
        // died after claiming and nothing will ever finish it. The worker only claims from
        // `queued` (see `processJob`), so re-publishing without this reset would leave the job
        // permanently unclaimable. The age check keeps a genuinely slow signing run safe: its
        // claim is recent, so it is left alone.
        if (row.state === 'running') {
          await infra.pool.query(
            "UPDATE jobs SET state='queued' WHERE id=$1 AND state='running' AND (started_at IS NULL OR started_at < now() - interval '30 minutes')",
            [row.id],
          );
        }
        // Publish before marking: the stable BullMQ ID deduplicates retries.
        await infra.queue.add('sign', { id: row.id }, {
          jobId: row.id, attempts: 3, backoff: { type: 'exponential', delay: 5000 },
          removeOnComplete: { age: 7 * 86400 }, removeOnFail: { age: 7 * 86400 },
        });
        await infra.pool.query('UPDATE jobs SET published_at=now() WHERE id=$1', [row.id]);
      } else if (await existing.getState() === 'failed') {
        await onFailed(row.id);
      }
    }
    this.cursor = pending.rows.length === 100 ? pending.rows[pending.rows.length - 1]!.id : null;
  }
}
