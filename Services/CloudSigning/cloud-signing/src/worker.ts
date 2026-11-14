import { Worker, type Job } from 'bullmq';
import { mkdtemp, chmod, rm, lstat, open } from 'node:fs/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Transform, type Readable } from 'node:stream';
import { createHash, createHmac, hkdfSync } from 'node:crypto';
import { GetObjectCommand } from '@aws-sdk/client-s3';
import { Upload } from '@aws-sdk/lib-storage';
import { loadConfig } from './config.js';
import { infrastructure } from './infrastructure.js';
import { unseal, permittedWebhook } from './security.js';
import { invokeSigner, type SignerInput } from './signer.js';

const config = loadConfig(); const infra = infrastructure(config);
const key = Buffer.from(config.ENCRYPTION_KEY, 'hex');

async function fetchAsset(id: string, owner: string, destination: string, kind: string) {
  const result = await infra.pool.query('SELECT object_key,sha256,bytes FROM assets WHERE id=$1 AND owner=$2 AND kind=$3', [id, owner, kind]);
  const asset = result.rows[0]; if (!asset) throw new Error('ASSET_MISSING');
  const response = await infra.s3.send(new GetObjectCommand({ Bucket: config.S3_BUCKET, Key: asset.object_key }));
  if (!response.Body) throw new Error('ASSET_MISSING');
  const digest = createHash('sha256'); let bytes = 0;
  const check = new Transform({ transform(chunk: Buffer, _encoding, callback) {
    bytes += chunk.length;
    if (bytes > Number(asset.bytes)) return callback(new Error('INTEGRITY_ERROR'));
    digest.update(chunk); callback(null, chunk);
  } });
  await pipeline(response.Body as Readable, check, createWriteStream(destination, { flags: 'wx', mode: 0o600 }));
  if (bytes !== Number(asset.bytes) || digest.digest('hex') !== asset.sha256) throw new Error('INTEGRITY_ERROR');
}
async function finish(id: string, state: 'completed' | 'failed', result: unknown, outputKey: string | null, digest: string | null) {
  const client = await infra.pool.connect();
  try {
    await client.query('BEGIN');
    const data = await client.query(`UPDATE jobs SET state=$2,result=$3,output_key=$4,output_sha256=$5,
      sealed_password=NULL,error_code=$6,finished_at=now() WHERE id=$1 AND state NOT IN ('completed','failed') RETURNING owner,webhook`,
      [id, state, result, outputKey, digest, state === 'failed' ? 'SIGNING_FAILED' : null]);
    const row = data.rows[0];
    if (row) {
      await client.query('INSERT INTO audit_logs(owner,action,resource_id) VALUES($1,$2,$3)', [row.owner, `job.${state}`, id]);
      if (row.webhook) await client.query(`INSERT INTO webhook_deliveries(job_id,owner,url,payload) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`,
        [id, row.owner, row.webhook, { jobId: id, state }]);
    }
    await client.query('COMMIT');
  } catch (error) { await client.query('ROLLBACK'); throw error; }
  finally { client.release(); }
}
async function processJob(job: Job<{ id: string }>) {
  const row = (await infra.pool.query('SELECT * FROM jobs WHERE id=$1', [job.data.id])).rows[0];
  if (!row || row.state === 'completed' || row.state === 'failed') return;
  const directory = await mkdtemp(join(tmpdir(), 'vexsign-job-')); await chmod(directory, 0o700);
  try {
    await infra.pool.query("UPDATE jobs SET state='running',started_at=now() WHERE id=$1", [row.id]);
    const input: SignerInput = {
      protocolVersion: 1, kind: row.kind, directory,
      p12Path: join(directory, 'identity.p12'), provisionPath: join(directory, 'profile.mobileprovision'),
      outputPath: join(directory, 'signed.ipa'), password: unseal(row.sealed_password, key, row.id),
    };
    await fetchAsset(row.p12_id, row.owner, input.p12Path, 'p12');
    await fetchAsset(row.provision_id, row.owner, input.provisionPath, 'provision');
    if (row.kind === 'sign') {
      input.ipaPath = join(directory, 'input.ipa');
      await fetchAsset(row.ipa_id, row.owner, input.ipaPath, 'ipa');
    }
    const signed = await invokeSigner(config.SIGNER_EXECUTABLE, input);
    input.password = ''; // JS runtimes cannot guarantee memory zeroization.
    if (signed.kind === 'check-cert') { await finish(row.id, 'completed', signed.certificate, null, null); return; }
    const stat = await lstat(input.outputPath);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size <= 4 || stat.size > 2 * 1024 ** 3) throw new Error('INVALID_OUTPUT');
    const file = await open(input.outputPath, 'r');
    try { const prefix = Buffer.alloc(4); await file.read(prefix, 0, 4, 0); if (!prefix.equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]))) throw new Error('INVALID_OUTPUT'); }
    finally { await file.close(); }
    const outputKey = `outputs/${row.id}.ipa`;
    const digest = createHash('sha256');
    const body = createReadStream(input.outputPath);
    body.on('data', chunk => digest.update(chunk));
    await new Upload({ client: infra.s3, params: { Bucket: config.S3_BUCKET, Key: outputKey, Body: body,
      ContentType: 'application/octet-stream', ...infra.encryption }, queueSize: 2, partSize: 8 * 1024 ** 2 }).done();
    await finish(row.id, 'completed', signed.metadata, outputKey, digest.digest('hex'));
  } catch {
    if (job.attemptsMade + 1 >= (job.opts.attempts ?? 1)) await finish(row.id, 'failed', null, null, null);
    else await infra.pool.query("UPDATE jobs SET state='queued',error_code='RETRY_PENDING' WHERE id=$1 AND state='running'", [row.id]);
    throw new Error('SIGNING_FAILED');
  } finally { await rm(directory, { recursive: true, force: true }); }
}

const worker = new Worker('vexsign-signing-v1', processJob, {
  connection: infra.redis, concurrency: config.SIGNING_CONCURRENCY, lockDuration: 60_000, maxStalledCount: 2,
});
worker.on('error', () => { console.error('Worker infrastructure error'); });
let polling = false;
async function dispatch() {
  if (polling) return; polling = true;
  try {
    // PostgreSQL is the source of truth. Publish-before-mark is safe: BullMQ job IDs dedupe.
    // Include already-published rows so a Redis restore/loss does not strand queued work.
    const pending = await infra.pool.query("SELECT id,state FROM jobs WHERE state IN ('queued','running') ORDER BY created_at LIMIT 100");
    for (const row of pending.rows) {
      const existing = await infra.queue.getJob(row.id);
      if (!existing) {
        await infra.queue.add('sign', { id: row.id }, { jobId: row.id, attempts: 3, backoff: { type: 'exponential', delay: 5000 }, removeOnComplete: { age: 7 * 86400 }, removeOnFail: { age: 7 * 86400 } });
        await infra.pool.query('UPDATE jobs SET published_at=now() WHERE id=$1', [row.id]);
      } else if (await existing.getState() === 'failed') {
        await finish(row.id, 'failed', null, null, null);
      }
    }
    await deliverWebhooks();
  } catch { console.error('Dispatch unavailable; retrying on next interval'); }
  finally { polling = false; }
}
async function deliverWebhooks() {
  // Transactional claim with a lease supports multiple worker replicas.
  const records = await infra.pool.query(`UPDATE webhook_deliveries SET attempts=attempts+1,next_attempt_at=now()+interval '5 minutes'
    WHERE job_id IN (SELECT job_id FROM webhook_deliveries WHERE delivered_at IS NULL AND attempts<8 AND next_attempt_at<=now()
      ORDER BY next_attempt_at FOR UPDATE SKIP LOCKED LIMIT 10) RETURNING *`);
  for (const row of records.rows) {
    if (!permittedWebhook(row.url, config.WEBHOOK_ALLOWLIST)) continue;
    const timestamp = String(Math.floor(Date.now() / 1000)); const payload = JSON.stringify(row.payload);
    const webhookKey = Buffer.from(hkdfSync('sha256', key, '', `vexsign.webhook.v1:${row.url}`, 32));
    const signature = createHmac('sha256', webhookKey).update(`${timestamp}.${payload}`).digest('hex');
    try {
      // URLs are operator-registered EXACT matches. Deployment egress firewall must
      // block private/link-local addresses and DNS rebinding for these destinations.
      const response = await fetch(row.url, { method: 'POST', body: payload, redirect: 'error', signal: AbortSignal.timeout(10_000),
        headers: { 'content-type': 'application/json', 'x-vexsign-timestamp': timestamp, 'x-vexsign-signature': signature, 'x-vexsign-event-id': row.job_id } });
      await response.body?.cancel();
      if (response.ok) await infra.pool.query('UPDATE webhook_deliveries SET delivered_at=now() WHERE job_id=$1', [row.job_id]);
    } catch { /* Persisted lease enables retry without logging secret endpoint URLs. */ }
  }
}
const timer = setInterval(() => { void dispatch(); }, 5000);
await dispatch();
let closing = false;
for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => { void (async () => {
  if (closing) return; closing = true; clearInterval(timer);
  await worker.close();
  while (polling) await new Promise(resolve => setTimeout(resolve, 50));
  await infra.close();
})(); });
