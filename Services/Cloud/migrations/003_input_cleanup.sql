-- Durable deletion intent prevents new job references before external S3 deletion.
ALTER TABLE assets ADD COLUMN IF NOT EXISTS deletion_requested_at timestamptz;
CREATE INDEX IF NOT EXISTS assets_cleanup_idx ON assets(created_at) WHERE purged_at IS NULL;
