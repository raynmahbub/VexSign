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
      const redisState = existing ? await existing.getState() : null;
      if (!existing || redisState === 'completed') {
        // Never publish an unclaimable running row. A fresh claim may still belong
        // to a live worker after Redis loss; only recover after its safety window.
        if (row.state === 'running') {
          const reset = await infra.pool.query(
            "UPDATE jobs SET state='queued' WHERE id=$1 AND state='running' AND (started_at IS NULL OR started_at < now() - interval '30 minutes')",
            [row.id],
          );
          if (!reset.rowCount) continue;
        }
        // A stalled redelivery can finish in Redis without claiming the DB row.
        // Remove that terminal delivery so the stable ID can be published again.
        if (existing) await existing.remove();
        // Publish before marking: the stable BullMQ ID deduplicates retries.
        await infra.queue.add('sign', { id: row.id }, {
          jobId: row.id, attempts: 3, backoff: { type: 'exponential', delay: 5000 },
          removeOnComplete: { age: 7 * 86400 }, removeOnFail: { age: 7 * 86400 },
        });
        await infra.pool.query('UPDATE jobs SET published_at=now() WHERE id=$1', [row.id]);
      } else if (redisState === 'failed') {
        await onFailed(row.id);
      }
    }
    this.cursor = pending.rows.length === 100 ? pending.rows[pending.rows.length - 1]!.id : null;
  }
}
