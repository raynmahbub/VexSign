import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, createSign, randomBytes } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { Readable } from 'node:stream';
import type { Job } from 'bullmq';
import { DeleteObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { buildApp } from '../API/Routes/app.js';
import { artifactMetadata } from '../API/DTOs/contracts.js';
import type { Config } from '../Configuration/config.js';
import type { Infrastructure } from '../Storage/infrastructure.js';
import { capability, seal } from '../Security/security.js';
import { submitJobs, type Submission } from '../Signing/JobQueue/jobs.js';
import { createWorkerRuntime } from '../Signing/Worker/processor.js';

const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const encryptionKey = randomBytes(32).toString('hex');
const config: Config = {
  DATABASE_URL: 'unused',
  REDIS_URL: 'redis://unused',
  S3_ENDPOINT: 'https://storage.test',
  S3_REGION: 'test',
  S3_BUCKET: 'bucket-test',
  PUBLIC_ORIGIN: 'https://install.test',
  JWT_PUBLIC_KEY_FILE: 'unused',
  JWT_ISSUER: 'https://auth.test',
  JWT_AUDIENCE: 'signing',
  jwtPublicKey: publicKey.export({ type: 'spki', format: 'pem' }).toString(),
  ENCRYPTION_KEY: encryptionKey,
  PORT: 8080,
  SIGNER_EXECUTABLE: '/unused',
  SIGNING_CONCURRENCY: 1,
  WEBHOOK_ALLOWLIST: 'https://hooks.example.com/vexsign',
  TRUSTED_PROXIES: '',
};

function jwtFor(sub: string) {
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({
    sub,
    iss: config.JWT_ISSUER,
    aud: config.JWT_AUDIENCE,
    exp: Math.floor(Date.now() / 1000) + 600,
    iat: Math.floor(Date.now() / 1000),
    scope: 'signing:write',
  })).toString('base64url');
  const body = `${header}.${claims}`;
  return `${body}.${createSign('RSA-SHA256').update(body).sign(privateKey).toString('base64url')}`;
}

test('artifactMetadata accepts underscored bundle identifiers and OTA contract drift returns 500', async () => {
  const parsed = artifactMetadata.parse({
    name: 'My App',
    bundleIdentifier: 'com.my_org.my_app_1',
    version: '1.2.0',
  });
  assert.equal(parsed.bundleIdentifier, 'com.my_org.my_app_1');

  const id = '01234567-89ab-4def-8123-456789abcdef';
  const validToken = capability(id, Math.floor(Date.now() / 1000) + 600, Buffer.from(encryptionKey, 'hex'));

  const okApp = await buildApp(config, {
    redis: { defineCommand() {}, rateLimit(...args: unknown[]) { (args.at(-1) as Function)(null, [1, 60_000]); }, eval: async () => 1, ping: async () => 'PONG' },
    pool: { query: async () => ({ rows: [{ output_key: 'outputs/ok.ipa', result: { name: 'My App', bundleIdentifier: 'com.my_org.my_app', version: '1.0', changelog: '', screenshotURLs: [] } }] }) },
  } as unknown as Infrastructure);
  try {
    const manifestRes = await okApp.inject({ method: 'GET', url: `/manifest/${id}?token=${encodeURIComponent(validToken)}` });
    assert.equal(manifestRes.statusCode, 200);
    assert.ok(manifestRes.body.includes('com.my_org.my_app'));
  } finally {
    await okApp.close();
  }

  const driftedApp = await buildApp(config, {
    redis: { defineCommand() {}, rateLimit(...args: unknown[]) { (args.at(-1) as Function)(null, [1, 60_000]); }, eval: async () => 1, ping: async () => 'PONG' },
    pool: { query: async () => ({ rows: [{ output_key: 'outputs/drifted.ipa', result: { broken: true } }] }) },
  } as unknown as Infrastructure);
  try {
    const driftedRes = await driftedApp.inject({ method: 'GET', url: `/manifest/${id}?token=${encodeURIComponent(validToken)}` });
    assert.equal(driftedRes.statusCode, 500);
    assert.equal(driftedRes.json().error, 'Service unavailable');
  } finally {
    await driftedApp.close();
  }
});

test('upload endpoint rejects non-ZIP IPA magic with 400 and cleans up S3 object', async () => {
  const deletedKeys: string[] = [];
  const app = await buildApp(config, {
    redis: { defineCommand() {}, rateLimit(...args: unknown[]) { (args.at(-1) as Function)(null, [1, 60_000]); }, eval: async () => 1, ping: async () => 'PONG' },
    pool: { query: async () => ({ rows: [] }), connect: async () => ({ query: async () => ({ rows: [] }), release() {} }) },
    s3: {
      send: async (cmd: unknown) => {
        if (cmd instanceof DeleteObjectCommand) deletedKeys.push(cmd.input.Key ?? '');
        return {};
      },
    },
    encryption: { ServerSideEncryption: 'AES256' },
  } as unknown as Infrastructure);
  try {
    const boundary = '----vexsignBoundary';
    const payload = Buffer.concat([
      Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="bad.ipa"\r\nContent-Type: application/octet-stream\r\n\r\n`),
      Buffer.from('NOT_A_ZIP_ARCHIVE_PAYLOAD'),
      Buffer.from(`\r\n--${boundary}--\r\n`),
    ]);
    const res = await app.inject({
      method: 'POST',
      url: '/api/upload?kind=ipa',
      headers: {
        authorization: `Bearer ${jwtFor('tenant-upload')}`,
        'content-type': `multipart/form-data; boundary=${boundary}`,
      },
      payload,
    });
    assert.equal(res.statusCode, 400);
    assert.equal(res.json().error, 'IPA must be a ZIP archive');
    assert.equal(deletedKeys.length, 1);
  } finally {
    await app.close();
  }
});

test('submitJobs publishes immediately to BullMQ and survives transient Redis unavailability', async () => {
  const published: string[] = [];
  const submission: Submission = {
    ipaId: 'ipa-1',
    p12Id: 'p12-1',
    provisionId: 'prov-1',
    password: 'secret',
    idempotencyKey: '01234567-89ab-4def-8123-456789abcdef',
  };
  const makeInfra = (failQueue: boolean) => ({
    pool: {
      query: async () => ({ rows: [] }),
      connect: async () => ({
        async query(sql: string) {
          if (sql.includes('count(*)')) return { rows: [{ count: 0 }] };
          if (sql.includes('idempotency_key=$2')) return { rows: [], rowCount: 0 };
          if (sql.includes('SELECT id, kind FROM assets')) {
            return { rows: [{ id: 'ipa-1', kind: 'ipa' }, { id: 'p12-1', kind: 'p12' }, { id: 'prov-1', kind: 'provision' }] };
          }
          return { rows: [], rowCount: 1 };
        },
        release() {},
      }),
    },
    queue: {
      async add(_name: string, data: { id: string }) {
        if (failQueue) throw new Error('redis down');
        published.push(data.id);
      },
    },
  }) as unknown as Infrastructure;

  const key = randomBytes(32);
  const [okJob] = await submitJobs(makeInfra(false), key, 'owner-1', 'sign', [submission]);
  assert.deepEqual(published, [okJob!.id]);

  const [fallbackJob] = await submitJobs(makeInfra(true), key, 'owner-1', 'sign', [submission]);
  assert.equal(fallbackJob!.state, 'queued');
});

test('worker signs IPA, purges unreferenced S3 input objects, and prunes old webhook deliveries', async () => {
  const key = Buffer.from(encryptionKey, 'hex');
  const jobId = '01234567-89ab-4def-8123-456789abcdef';
  const p12Bytes = Buffer.from('mock-p12-bytes');
  const provBytes = Buffer.from('mock-prov-bytes');
  const ipaBytes = Buffer.from([0x50, 0x4b, 0x03, 0x04, 1, 2, 3, 4]);
  const signedBytes = Buffer.from([0x50, 0x4b, 0x03, 0x04, 9, 8, 7, 6]);

  const assets: Record<string, { object_key: string; sha256: string; bytes: number; data: Buffer }> = {
    'p12-id': { object_key: 'inputs/p12-id', sha256: createHash('sha256').update(p12Bytes).digest('hex'), bytes: p12Bytes.length, data: p12Bytes },
    'prov-id': { object_key: 'inputs/prov-id', sha256: createHash('sha256').update(provBytes).digest('hex'), bytes: provBytes.length, data: provBytes },
    'ipa-id': { object_key: 'inputs/ipa-id', sha256: createHash('sha256').update(ipaBytes).digest('hex'), bytes: ipaBytes.length, data: ipaBytes },
  };
  const s3Deleted: string[] = [];
  const purgedAssetIds: string[] = [];
  const uploadedOutputs: string[] = [];
  let prunedWebhooks = false;
  let deliveredWebhookId = '';

  const jobRow = {
    id: jobId,
    owner: 'tenant-1',
    kind: 'sign',
    state: 'queued',
    ipa_id: 'ipa-id',
    p12_id: 'p12-id',
    provision_id: 'prov-id',
    sealed_password: seal('cert-pass', key, jobId),
    webhook: 'https://hooks.example.com/vexsign',
  };

  const queryHandler = async (sql: string, params: unknown[] = []) => {
    if (sql.startsWith('SELECT * FROM jobs')) return { rows: [jobRow] };
    if (sql.startsWith('SELECT object_key,sha256,bytes FROM assets')) {
      const a = assets[params[0] as string];
      return { rows: a ? [a] : [] };
    }
    if (sql.includes('UPDATE jobs SET state=$2')) {
      jobRow.state = params[1] as string;
      return {
        rows: [{
          owner: jobRow.owner,
          webhook: jobRow.webhook,
          ipa_id: jobRow.ipa_id,
          p12_id: jobRow.p12_id,
          provision_id: jobRow.provision_id,
        }],
      };
    }
    if (sql.includes('FROM assets a') && sql.includes('NOT EXISTS')) {
      // Simulate p12-id still referenced by another queued batch job while ipa-id and prov-id are unreferenced.
      return {
        rows: [
          { id: 'ipa-id', object_key: 'inputs/ipa-id' },
          { id: 'prov-id', object_key: 'inputs/prov-id' },
        ],
      };
    }
    if (sql.startsWith('UPDATE assets SET purged_at=now()')) {
      purgedAssetIds.push(params[0] as string);
      return { rows: [] };
    }
    if (sql.startsWith('UPDATE webhook_deliveries SET attempts=attempts+1')) {
      return {
        rows: [{
          job_id: jobId,
          owner: 'tenant-1',
          url: 'https://hooks.example.com/vexsign',
          payload: { jobId, state: 'completed' },
        }],
      };
    }
    if (sql.startsWith('UPDATE webhook_deliveries SET delivered_at=now()')) {
      deliveredWebhookId = params[0] as string;
      return { rows: [] };
    }
    if (sql.startsWith('DELETE FROM webhook_deliveries')) {
      prunedWebhooks = true;
      return { rows: [] };
    }
    return { rows: [] };
  };

  const infra = {
    pool: {
      query: queryHandler,
      connect: async () => ({ query: queryHandler, release() {} }),
    },
    s3: {
      send: async (cmd: unknown) => {
        if (cmd instanceof GetObjectCommand) {
          const found = Object.values(assets).find(v => v.object_key === cmd.input.Key);
          return { Body: found ? Readable.from([found.data]) : undefined };
        }
        if (cmd instanceof DeleteObjectCommand) {
          s3Deleted.push(cmd.input.Key ?? '');
          return {};
        }
        return {};
      },
    },
    encryption: { ServerSideEncryption: 'AES256' },
  } as unknown as Infrastructure;

  const runtime = createWorkerRuntime(config, infra, key, {
    invokeSigner: async (_exe, input) => {
      assert.equal(input.password, 'cert-pass');
      await writeFile(input.outputPath, signedBytes, { mode: 0o600 });
      return {
        kind: 'sign',
        signatureVerified: true,
        metadata: {
          name: 'Signed App',
          bundleIdentifier: 'com.my_org.signed_app',
          version: '2.0',
          changelog: '',
          screenshotURLs: [],
        },
      };
    },
    uploadOutput: async (_bucket, objectKey) => {
      uploadedOutputs.push(objectKey);
    },
    fetchFn: async () => new Response('ok', { status: 200 }),
  });

  await runtime.processJob({ data: { id: jobId }, attemptsMade: 0, opts: { attempts: 3 } } as unknown as Job<{ id: string }>);
  assert.equal(jobRow.state, 'completed');
  assert.deepEqual(uploadedOutputs, [`outputs/${jobId}.ipa`]);
  assert.deepEqual(s3Deleted, ['inputs/ipa-id', 'inputs/prov-id']);
  assert.deepEqual(purgedAssetIds, ['ipa-id', 'prov-id']);

  await runtime.deliverWebhooks();
  assert.equal(deliveredWebhookId, jobId);
  assert.equal(prunedWebhooks, true);
});
