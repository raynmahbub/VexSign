-- Align outbox/pending scan index with PendingJobDispatcher, index due webhooks,
-- and track purged input S3 objects while preserving job foreign-key history.
ALTER TABLE assets ADD COLUMN IF NOT EXISTS purged_at timestamptz;
DROP INDEX IF EXISTS jobs_outbox;
CREATE INDEX IF NOT EXISTS jobs_pending_scan_idx
    ON jobs (id)
    WHERE state IN ('queued', 'running');
CREATE INDEX IF NOT EXISTS webhook_deliveries_due_idx
    ON webhook_deliveries (next_attempt_at)
    WHERE delivered_at IS NULL AND attempts < 8;
