import pg from 'pg';
import { readFile } from 'node:fs/promises';
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const client = await pool.connect();
try {
  await client.query('BEGIN');
  await client.query('SELECT pg_advisory_xact_lock(991384012)');
  await client.query('CREATE TABLE IF NOT EXISTS schema_migrations (version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())');
  const applied = await client.query('SELECT version FROM schema_migrations WHERE version=1');
  if (!applied.rowCount) {
    await client.query(await readFile(new URL('../../migrations/001_initial.sql', import.meta.url), 'utf8').catch(() => readFile(new URL('../migrations/001_initial.sql', import.meta.url), 'utf8')));
    await client.query('INSERT INTO schema_migrations(version) VALUES(1)');
  }
  await client.query('COMMIT');
} catch (error) { await client.query('ROLLBACK'); throw error; }
finally { client.release(); await pool.end(); }
