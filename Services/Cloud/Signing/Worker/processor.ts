import { mkdtemp, chmod, rm, lstat, open } from 'node:fs/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Transform, type Readable } from 'node:stream';
import { createHash, createHmac, hkdfSync } from 'node:crypto';
import { DeleteObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { Upload } from '@aws-sdk/lib-storage';
import type { Job } from 'bullmq';
import type { Config } from '../../Configuration/config.js';
import type { Infrastructure } from '../../VexSign/Storage/infrastructure.js';
import { unseal, permittedWebhook } from '../../Security/security.js';
import { invokeSigner as defaultInvokeSigner, type SignerInput } from '../CloudSigningCoordinator/signer.js';

/**
 * The job pipeline, separated from the process that runs it.
 *
 * Everything here takes its dependencies as an argument, so `worker.ts` stays a thin entrypoint and
 * tests can inject fakes the way `Tests/api.test.ts` does for `buildApp`.
 */
export type WorkerDependencies = {
  invokeSigner?: typeof defaultInvokeSigner;
  uploadOutput?: (bucket: string, objectKey: string, filePath: string) => Promise<void>;
  fetchFn?: typeof fetch;
};

export type WorkerDeps = {
  config: Config;
  infra: Infrastructure;
  key: Buffer;
} & WorkerDependencies;

/**
 * The failure reasons this module raises. Each is a fixed string with nothing interpolated into it,
 * so it is safe to log and to store in `jobs.error_code`. Every other error — a `pg`, `ioredis` or
 * AWS SDK failure — can carry a DSN, an object key or a filesystem path in its message, so
 * `failureCode` reduces those to a type name instead of repeating them.
 */
const SENTINELS = new Set(['ASSET_MISSING', 'INTEGRITY_ERROR', 'INVALID_OUTPUT', 'SIGNER_FAILED', 'INVALID_SIGNER_RESULT']);

export function failureCode(error: unknown): string {
  if (error instanceof Error && SENTINELS.has(error.message)) return error.message;
  return error instanceof Error ? error.constructor.name : 'UnknownError';
}

/**
 * Wraps `source` so its bytes are hashed as they flow to whoever consumes the result.
 */
export function hashingStream(source: Readable): { body: Readable; hex: () => string } {
  const digest = createHash('sha256');
  const body = source.pipe(
    new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        digest.update(chunk);
        callback(null, chunk);
      },
    }),
  );
  // `.pipe` does not forward a source error to its destination, so a vanished or unreadable artifact
  // would otherwise stall the upload instead of failing the job.
  source.on('error', error => body.destroy(error));
  return { body, hex: () => digest.digest('hex') };
}

export async function fetchAsset(
  deps: WorkerDeps,
  id: string,
  owner: string,
  destination: string,
  kind: string,
): Promise<void> {
  const { config, infra } = deps;
  const result = await infra.pool.query(
    'SELECT object_key,sha256,bytes FROM assets WHERE id=$1 AND owner=$2 AND kind=$3 AND purged_at IS NULL',
    [id, owner, kind],
  );
  const asset = result.rows[0];
  if (!asset) throw new Error('ASSET_MISSING');
  const response = await infra.s3.send(new GetObjectCommand({ Bucket: config.S3_BUCKET, Key: asset.object_key }));
  if (!response.Body) throw new Error('ASSET_MISSING');
  const digest = createHash('sha256');
  let bytes = 0;
  const check = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      bytes += chunk.length;
      if (bytes > Number(asset.bytes)) return callback(new Error('INTEGRITY_ERROR'));
      digest.update(chunk);
      callback(null, chunk);
    },
  });
  // `wx` so a leftover file from a crashed run can never be silently reused or appended to.
  await pipeline(response.Body as Readable, check, createWriteStream(destination, { flags: 'wx', mode: 0o600 }));
  if (bytes !== Number(asset.bytes) || digest.digest('hex') !== asset.sha256) throw new Error('INTEGRITY_ERROR');
}

export async function purgeUnreferencedJobInputs(deps: WorkerDeps, owner: string, assetIds: string[]): Promise<void> {
  const uniqueIds = [...new Set(assetIds.filter(Boolean))];
  if (!uniqueIds.length || !deps.infra.s3) return;
  try {
    const candidates = await deps.infra.pool.query<{ id: string; object_key: string }>(
      `SELECT a.id, a.object_key
         FROM assets a
        WHERE a.owner = $1
          AND a.purged_at IS NULL
          AND a.id = ANY($2::uuid[])
          AND NOT EXISTS (
            SELECT 1
              FROM jobs j
             WHERE j.owner = $1
               AND j.state IN ('queued', 'running')
               AND (j.ipa_id = a.id OR j.p12_id = a.id OR j.provision_id = a.id)
          )`,
      [owner, uniqueIds],
    );
    for (const asset of candidates.rows) {
      await deps.infra.s3.send(new DeleteObjectCommand({ Bucket: deps.config.S3_BUCKET, Key: asset.object_key }));
      await deps.infra.pool.query('UPDATE assets SET purged_at=now() WHERE id=$1 AND owner=$2', [asset.id, owner]);
    }
  } catch {
    // Best-effort S3 input purge; never fail an already-recorded terminal job transition.
  }
}

export async function finish(
  deps: WorkerDeps,
  id: string,
  state: 'completed' | 'failed',
  result: unknown,
  outputKey: string | null,
  digest: string | null,
  code: string | null = null,
): Promise<void> {
  const client = await deps.infra.pool.connect();
  let finalizedRow:
    | { owner: string; webhook: string | null; ipa_id?: string | null; p12_id?: string; provision_id?: string }
    | undefined;
  try {
    await client.query('BEGIN');
    const data = await client.query(
      `UPDATE jobs SET state=$2,result=$3,output_key=$4,output_sha256=$5,
        sealed_password=NULL,error_code=$6,finished_at=now()
       WHERE id=$1 AND state NOT IN ('completed','failed')
       RETURNING owner,webhook,ipa_id,p12_id,provision_id`,
      [id, state, result, outputKey, digest, state === 'failed' ? (code ?? 'SIGNING_FAILED') : null],
    );
    finalizedRow = data.rows[0];
    if (finalizedRow) {
      await client.query('INSERT INTO audit_logs(owner,action,resource_id) VALUES($1,$2,$3)', [
        finalizedRow.owner,
        `job.${state}`,
        id,
      ]);
      if (finalizedRow.webhook) {
        await client.query(
          'INSERT INTO webhook_deliveries(job_id,owner,url,payload) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING',
          [id, finalizedRow.owner, finalizedRow.webhook, { jobId: id, state }],
        );
      }
    }
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
  if (finalizedRow) {
    await purgeUnreferencedJobInputs(
      deps,
      finalizedRow.owner,
      [finalizedRow.ipa_id ?? '', finalizedRow.p12_id ?? '', finalizedRow.provision_id ?? ''].filter(Boolean),
    );
  }
}

export async function processJob(deps: WorkerDeps, job: Job<{ id: string }>): Promise<void> {
  const { config, infra, key } = deps;
  const runSigner = deps.invokeSigner ?? defaultInvokeSigner;
  const row = (await infra.pool.query('SELECT * FROM jobs WHERE id=$1', [job.data.id])).rows[0];
  if (!row || row.state === 'completed' || row.state === 'failed') return;
  // Declared outside the try so a failure to create the directory is still reported as a failed job
  // rather than leaving it stuck in `queued` with nothing in the log.
  let directory: string | null = null;
  try {
    // Claim the row instead of overwriting it. The dispatcher re-publishes rows that are still
    // `queued` or `running`, and BullMQ retries a stalled delivery while the previous attempt may
    // still be signing, so two attempts can enter this function for one job. Winning the
    // `queued → running` transition is what makes the run exclusive; the loser must not fetch
    // assets, run the signer, or write a result the winner is about to overwrite.
    const claim = await infra.pool.query(
      "UPDATE jobs SET state='running',started_at=now() WHERE id=$1 AND state='queued'",
      [row.id],
    );
    if (!claim.rowCount) return;
    directory = await mkdtemp(join(tmpdir(), 'vexsign-job-'));
    await chmod(directory, 0o700);
    const input: SignerInput = {
      protocolVersion: 1,
      kind: row.kind,
      directory,
      p12Path: join(directory, 'identity.p12'),
      provisionPath: join(directory, 'profile.mobileprovision'),
      outputPath: join(directory, 'signed.ipa'),
      password: unseal(row.sealed_password, key, row.id),
    };
    await fetchAsset(deps, row.p12_id, row.owner, input.p12Path, 'p12');
    await fetchAsset(deps, row.provision_id, row.owner, input.provisionPath, 'provision');
    if (row.kind === 'sign') {
      input.ipaPath = join(directory, 'input.ipa');
      await fetchAsset(deps, row.ipa_id, row.owner, input.ipaPath, 'ipa');
    }
    const signed = await runSigner(config.SIGNER_EXECUTABLE, input);
    input.password = ''; // JS runtimes cannot guarantee memory zeroization.
    if (signed.kind === 'check-cert') {
      await finish(deps, row.id, 'completed', signed.certificate, null, null);
      return;
    }
    const stat = await lstat(input.outputPath);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size <= 4 || stat.size > 2 * 1024 ** 3) {
      throw new Error('INVALID_OUTPUT');
    }
    const file = await open(input.outputPath, 'r');
    try {
      const prefix = Buffer.alloc(4);
      await file.read(prefix, 0, 4, 0);
      if (!prefix.equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]))) throw new Error('INVALID_OUTPUT');
    } finally {
      await file.close();
    }
    const outputKey = `outputs/${row.id}.ipa`;
    const artifact = hashingStream(createReadStream(input.outputPath));
    if (deps.uploadOutput) {
      for await (const _chunk of artifact.body) {
        /* drain through hashingStream before custom test uploader */
      }
      await deps.uploadOutput(config.S3_BUCKET, outputKey, input.outputPath);
    } else {
      await new Upload({
        client: infra.s3,
        params: {
          Bucket: config.S3_BUCKET,
          Key: outputKey,
          Body: artifact.body,
          ContentType: 'application/octet-stream',
          ...infra.encryption,
        },
        queueSize: 2,
        partSize: 8 * 1024 ** 2,
        leavePartsOnError: false,
      }).done();
    }
    await finish(deps, row.id, 'completed', signed.metadata, outputKey, artifact.hex());
  } catch (error) {
    const code = failureCode(error);
    console.error(`job ${row.id} failed: ${code}`);
    if (job.attemptsMade + 1 >= (job.opts.attempts ?? 1)) await finish(deps, row.id, 'failed', null, null, null, code);
    else {
      await infra.pool.query("UPDATE jobs SET state='queued',error_code='RETRY_PENDING' WHERE id=$1 AND state='running'", [
        row.id,
      ]);
    }
    throw new Error('SIGNING_FAILED');
  } finally {
    if (directory) await rm(directory, { recursive: true, force: true });
  }
}

export async function deliverWebhooks(deps: WorkerDeps): Promise<void> {
  const { config, infra, key } = deps;
  const runFetch = deps.fetchFn ?? globalThis.fetch;
  // Transactional claim with a lease supports multiple worker replicas.
  const records = await infra.pool.query(
    `UPDATE webhook_deliveries SET attempts=attempts+1,next_attempt_at=now()+interval '5 minutes'
      WHERE job_id IN (
        SELECT job_id FROM webhook_deliveries
         WHERE delivered_at IS NULL AND attempts<8 AND next_attempt_at<=now()
         ORDER BY next_attempt_at FOR UPDATE SKIP LOCKED LIMIT 10
      ) RETURNING *`,
  );
  for (const row of records.rows) {
    if (!permittedWebhook(row.url, config.WEBHOOK_ALLOWLIST)) continue;
    const timestamp = String(Math.floor(Date.now() / 1000));
    const payload = JSON.stringify(row.payload);
    const webhookKey = Buffer.from(hkdfSync('sha256', key, '', `vexsign.webhook.v1:${row.url}`, 32));
    const signature = createHmac('sha256', webhookKey).update(`${timestamp}.${payload}`).digest('hex');
    try {
      // URLs are operator-registered EXACT matches. Deployment egress firewall must
      // block private/link-local addresses and DNS rebinding for these destinations.
      const response = await runFetch(row.url, {
        method: 'POST',
        body: payload,
        redirect: 'error',
        signal: AbortSignal.timeout(10_000),
        headers: {
          'content-type': 'application/json',
          'x-vexsign-timestamp': timestamp,
          'x-vexsign-signature': signature,
          'x-vexsign-event-id': row.job_id,
        },
      });
      await response.body?.cancel();
      if (response.ok) await infra.pool.query('UPDATE webhook_deliveries SET delivered_at=now() WHERE job_id=$1', [row.job_id]);
    } catch (error) {
      // The endpoint URL is secret and stays out of the log; the lease persists the retry.
      console.error(`webhook for job ${row.job_id} failed: ${failureCode(error)}`);
    }
  }
}

export async function pruneWebhooks(deps: WorkerDeps): Promise<void> {
  await deps.infra.pool.query(
    "DELETE FROM webhook_deliveries WHERE (delivered_at IS NOT NULL OR attempts >= 8) AND next_attempt_at < now() - interval '7 days'",
  );
}

export function createWorkerRuntime(
  config: Config,
  infra: Infrastructure,
  key: Buffer,
  overrides: WorkerDependencies = {},
) {
  const deps: WorkerDeps = { config, infra, key, ...overrides };
  return {
    fetchAsset: (id: string, owner: string, destination: string, kind: string) =>
      fetchAsset(deps, id, owner, destination, kind),
    purgeUnreferencedJobInputs: (owner: string, assetIds: string[]) =>
      purgeUnreferencedJobInputs(deps, owner, assetIds),
    finish: (
      id: string,
      state: 'completed' | 'failed',
      result: unknown,
      outputKey: string | null,
      digest: string | null,
      code: string | null = null,
    ) => finish(deps, id, state, result, outputKey, digest, code),
    processJob: (job: Job<{ id: string }>) => processJob(deps, job),
    deliverWebhooks: async () => {
      await deliverWebhooks(deps);
      await pruneWebhooks(deps);
    },
    pruneWebhooks: () => pruneWebhooks(deps),
  };
}
