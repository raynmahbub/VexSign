import { createHmac, randomUUID } from 'node:crypto';
import type { Infrastructure } from './infrastructure.js';
import { seal } from './security.js';
import type { SignRequest } from './contracts.js';

export class APIError extends Error {
  constructor(readonly statusCode: number, message: string) { super(message); }
}
export type Submission = Omit<SignRequest, 'ipaId'> & { ipaId?: string; idempotencyKey: string };
export async function submitJobs(infra: Infrastructure, key: Buffer, owner: string, kind: 'sign' | 'check-cert', requests: Submission[]) {
  const client = await infra.pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [owner]);
    const active = await client.query("SELECT count(*)::int AS count FROM jobs WHERE owner=$1 AND state IN ('queued','running')", [owner]);
    let activeCount = Number(active.rows[0].count);
    const result: { id: string; state: string }[] = [];
    for (const request of requests) {
      const hash = createHmac('sha256', key).update(JSON.stringify([kind, request.ipaId ?? null, request.p12Id, request.provisionId, request.password, request.webhook ?? null])).digest('hex');
      const prior = await client.query('SELECT id, state, request_hash FROM jobs WHERE owner=$1 AND idempotency_key=$2', [owner, request.idempotencyKey]);
      if (prior.rowCount) {
        if (prior.rows[0].request_hash !== hash) throw new APIError(409, 'Idempotency key already used for a different request');
        result.push({ id: prior.rows[0].id, state: prior.rows[0].state }); continue;
      }
      if (++activeCount > 100) throw new APIError(429, 'Active job quota exceeded');
      const assets = await client.query('SELECT id, kind FROM assets WHERE owner=$1 AND id=ANY($2::uuid[])', [owner, [request.ipaId, request.p12Id, request.provisionId].filter(Boolean)]);
      const matches = (id: string | undefined, expected: string) => assets.rows.some(row => row.id === id && row.kind === expected);
      if (!matches(request.p12Id, 'p12') || !matches(request.provisionId, 'provision') || (kind === 'sign' && !matches(request.ipaId, 'ipa'))) throw new APIError(404, 'Signing assets not found');
      const id = randomUUID();
      await client.query(`INSERT INTO jobs(id,owner,kind,idempotency_key,request_hash,ipa_id,p12_id,provision_id,sealed_password,webhook)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`, [id, owner, kind, request.idempotencyKey, hash, request.ipaId ?? null, request.p12Id, request.provisionId, seal(request.password, key, id), request.webhook ?? null]);
      await client.query("INSERT INTO audit_logs(owner,action,resource_id) VALUES($1,'job.submitted',$2)", [owner, id]);
      result.push({ id, state: 'queued' });
    }
    await client.query('COMMIT'); return result;
  } catch (error) { await client.query('ROLLBACK'); throw error; }
  finally { client.release(); }
}
