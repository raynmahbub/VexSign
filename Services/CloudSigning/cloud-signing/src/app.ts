import Fastify, { LogController, type FastifyRequest } from 'fastify';
import jwt from '@fastify/jwt';
import helmet from '@fastify/helmet';
import multipart from '@fastify/multipart';
import rateLimit from '@fastify/rate-limit';
import { createHash, randomUUID } from 'node:crypto';
import { Readable } from 'node:stream';
import { Upload } from '@aws-sdk/lib-storage';
import { DeleteObjectCommand } from '@aws-sdk/client-s3';
import QRCode from 'qrcode';
import { z } from 'zod';
import type { Config } from './config.js';
import type { Infrastructure } from './infrastructure.js';
import { artifactMetadata, batchRequest, checkRequest, jobView, queueCounts, signRequest, uuid } from './contracts.js';
import { APIError, submitJobs, type Submission } from './jobs.js';
import { capability, permittedWebhook, verifyCapability } from './security.js';
import { installLink, installPage, manifest } from './ota.js';

const MAX_IPA = 2 * 1024 ** 3;
export async function buildApp(config: Config, infra: Infrastructure) {
  const key = Buffer.from(config.ENCRYPTION_KEY, 'hex');
  const proxies = config.TRUSTED_PROXIES.split(',').filter(Boolean);
  const app = Fastify({
    trustProxy: proxies.length ? proxies : false,
    bodyLimit: 64 * 1024, requestTimeout: 300_000,
    logger: { redact: ['req.headers.authorization', 'req.headers.cookie', 'req.body', 'req.query', 'res.headers.location'], serializers: {
      // Capability query strings and S3 signatures must not enter access logs.
      req: (req: { method: string; url: string }) => ({ method: req.method, path: req.url?.split('?')[0] }),
    } },
    logController: new LogController({ disableRequestLogging: true }),
  });
  await app.register(helmet, { contentSecurityPolicy: { directives: {
    defaultSrc: ["'none'"], imgSrc: ['https:', 'data:'], styleSrc: ["'self'"], scriptSrc: ["'self'"], frameAncestors: ["'none'"], baseUri: ["'none'"], formAction: ["'none'"],
  } }, referrerPolicy: { policy: 'no-referrer' } });
  await app.register(jwt, { secret: { public: config.jwtPublicKey.trim() }, verify: {
    algorithms: ['RS256'], allowedIss: config.JWT_ISSUER, allowedAud: config.JWT_AUDIENCE,
    requiredClaims: ['sub', 'exp', 'iat'], maxAge: 3600,
  } });
  await app.register(rateLimit, { max: 120, timeWindow: '1 minute', redis: infra.redis, skipOnError: false });
  await app.register(multipart, { limits: { files: 1, fields: 0, parts: 1, fileSize: MAX_IPA }, throwFileSizeLimit: true });

  const subject = (request: FastifyRequest) => (request.user as { sub: string }).sub;
  /**
   * Response validation. A ZodError from a *response* is not the client's fault, so it must not
   * reach the error handler's `400 Invalid request` path: it becomes a 500, which is retryable and
   * alerts, and it says nothing about the row that failed. Only the schema name is logged.
   */
  function contract<T>(schema: z.ZodType<T>, name: string, value: unknown, request: FastifyRequest): T {
    try {
      return schema.parse(value);
    } catch {
      request.log.error({ contract: name }, 'response contract violated');
      throw new APIError(500, 'Response contract violated');
    }
  }
  async function authenticate(request: FastifyRequest) {
    await request.jwtVerify();
    const claims = z.object({ sub: z.string().min(1).max(200), scope: z.string(), exp: z.number(), iat: z.number() }).parse(request.user);
    if (claims.iat > Math.floor(Date.now() / 1000) + 30 || claims.exp - claims.iat > 3600) throw new APIError(401, 'Invalid token lifetime');
    if (!claims.scope.split(' ').includes('signing:write')) throw new APIError(403, 'Missing signing scope');
    // Additional tenant throttling cannot be bypassed by cycling client IPs.
    const bucket = `vexsign:tenant:${createHash('sha256').update(claims.sub).digest('hex')}:${Math.floor(Date.now() / 60_000)}`;
    const count = await infra.redis.eval("local n=redis.call('INCR',KEYS[1]); if n==1 then redis.call('EXPIRE',KEYS[1],120) end; return n", 1, bucket);
    if (Number(count) > 60) throw new APIError(429, 'Tenant rate limit exceeded');
  }
  function validateWebhooks(requests: Submission[]) {
    if (requests.some(v => !permittedWebhook(v.webhook, config.WEBHOOK_ALLOWLIST))) throw new APIError(400, 'Webhook is not registered');
  }
  app.setErrorHandler((error, request, reply) => {
    if (error instanceof z.ZodError) return reply.code(400).send({ error: 'Invalid request', requestId: request.id });
    const status = error instanceof APIError ? error.statusCode : (error as { statusCode?: number }).statusCode ?? 500;
    // No raw validation payloads, signer output, credential strings, or SQL error details.
    return reply.code(status >= 400 && status < 600 ? status : 500).send({ error: status >= 500 ? 'Service unavailable' : error instanceof APIError ? error.message : 'Request rejected', requestId: request.id });
  });
  app.get('/assets/install.js', async (_request, reply) => reply.type('text/javascript').send(`
    document.getElementById('copy-link').addEventListener('click', async () => {
      const input = document.getElementById('install-link');
      try { await navigator.clipboard.writeText(input.value); document.getElementById('copy-link').textContent = 'Copied'; }
      catch { input.focus(); input.select(); document.getElementById('copy-link').textContent = 'Select and copy the link'; }
    });
  `));
  app.get('/assets/install.css', async (_request, reply) => reply.type('text/css').send(`
    :root{font-family:system-ui,sans-serif;color-scheme:light dark}body{margin:0;background:#101425;color:#f8f9ff}
    main{max-width:760px;margin:5vh auto;padding:32px;border:1px solid #ffffff20;border-radius:28px;background:#1b2238}
    h1{font-size:clamp(2rem,7vw,3.5rem);letter-spacing:-.05em}p{line-height:1.6;color:#c9d1ea}
    a,button{display:inline-block;padding:14px 22px;background:#798dff;color:#080d22;border:0;border-radius:14px;font:inherit;font-weight:650;text-decoration:none;cursor:pointer}
    input{display:block;box-sizing:border-box;width:100%;padding:12px;margin:12px 0;color:inherit;background:#101425;border:1px solid #ffffff40;border-radius:10px}
    img{max-width:100%;height:auto;border-radius:16px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;color:#c9d1ea}button:focus-visible,a:focus-visible{outline:3px solid white;outline-offset:4px}
    @media(max-width:600px){main{margin:16px;padding:22px}}
  `));
  app.get('/health/live', async () => ({ status: 'ok' }));
  app.get('/health/ready', async () => { await infra.pool.query('SELECT 1'); await infra.redis.ping(); return { status: 'ready' }; });
  app.post('/api/upload', { onRequest: authenticate, config: { rateLimit: { max: 10, timeWindow: '1 minute' } } }, async (request, reply) => {
    const { kind } = z.object({ kind: z.enum(['ipa', 'p12', 'provision']) }).strict().parse(request.query);
    const part = await request.file();
    if (!part) throw new APIError(400, 'One multipart file is required');
    const id = randomUUID(); const objectKey = `inputs/${id}`;
    const digest = createHash('sha256'); let bytes = 0; let prefix = Buffer.alloc(0);
    const limit = kind === 'ipa' ? MAX_IPA : 10 * 1024 ** 2;
    async function* chunks() {
      for await (const chunk of part!.file) {
        const data = Buffer.from(chunk); bytes += data.length;
        if (bytes > limit) throw new APIError(413, 'File too large');
        if (prefix.length < 4) prefix = Buffer.concat([prefix, data]).subarray(0, 4);
        digest.update(data); yield data;
      }
      if (!bytes || part!.file.truncated) throw new APIError(413, 'Empty or truncated upload');
      if (kind === 'ipa' && !prefix.equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]))) throw new APIError(400, 'IPA must be a ZIP archive');
    }
    const upload = new Upload({ client: infra.s3, params: { Bucket: config.S3_BUCKET, Key: objectKey,
      Body: Readable.from(chunks()), ContentType: 'application/octet-stream', ...infra.encryption },
      queueSize: 2, partSize: 8 * 1024 ** 2, leavePartsOnError: false });
    try {
      await upload.done();
      const sha256 = digest.digest('hex');
      const client = await infra.pool.connect();
      try {
        await client.query('BEGIN');
        await client.query('INSERT INTO assets(id,owner,kind,object_key,sha256,bytes) VALUES($1,$2,$3,$4,$5,$6)', [id, subject(request), kind, objectKey, sha256, bytes]);
        await client.query("INSERT INTO audit_logs(owner,action,resource_id) VALUES($1,'asset.uploaded',$2)", [subject(request), id]);
        await client.query('COMMIT');
      } catch (error) { await client.query('ROLLBACK'); throw error; } finally { client.release(); }
      return reply.code(201).send({ id, kind, sha256, bytes });
    } catch (error) {
      await upload.abort().catch(() => {});
      await infra.s3.send(new DeleteObjectCommand({ Bucket: config.S3_BUCKET, Key: objectKey })).catch(() => {});
      throw error;
    }
  });
  app.post('/api/sign', { onRequest: authenticate }, async (request, reply) => {
    const body = signRequest.parse(request.body);
    const submission = { ...body, idempotencyKey: uuid.parse(request.headers['idempotency-key']) };
    validateWebhooks([submission]);
    const [job] = await submitJobs(infra, key, subject(request), 'sign', [submission]);
    return reply.code(202).send(job);
  });
  app.post('/api/sign/batch', { onRequest: authenticate }, async (request, reply) => {
    const { jobs } = batchRequest.parse(request.body); validateWebhooks(jobs);
    if (new Set(jobs.map(v => v.idempotencyKey)).size !== jobs.length) throw new APIError(400, 'Duplicate idempotency keys');
    return reply.code(202).send({ jobs: await submitJobs(infra, key, subject(request), 'sign', jobs) });
  });
  app.post('/api/check-cert', { onRequest: authenticate }, async (request, reply) => {
    const body = checkRequest.parse(request.body);
    const submission = { ...body, idempotencyKey: uuid.parse(request.headers['idempotency-key']) }; validateWebhooks([submission]);
    const [job] = await submitJobs(infra, key, subject(request), 'check-cert', [submission]);
    return reply.code(202).send(job);
  });
  app.get('/api/jobs/:id', { onRequest: authenticate }, async request => {
    const { id } = z.object({ id: uuid }).parse(request.params);
    const data = await infra.pool.query('SELECT id,kind,state,result,error_code,output_sha256,created_at,finished_at FROM jobs WHERE id=$1 AND owner=$2', [id, subject(request)]);
    const row = data.rows[0]; if (!row) throw new APIError(404, 'Job not found');
    // Validated, not merely returned: the client decodes this shape, so a column that is
    // renamed or dropped fails here instead of in an app nobody can debug.
    return contract(jobView, 'JobView', {
      id: row.id, kind: row.kind, state: row.state, result: row.result,
      error_code: row.error_code, output_sha256: row.output_sha256,
      created_at: new Date(row.created_at).toISOString(),
      finished_at: row.finished_at ? new Date(row.finished_at).toISOString() : null,
      ...(row.state === 'completed' && row.kind === 'sign'
        ? { installURL: `${config.PUBLIC_ORIGIN}/install/${id}?token=${capability(id, Math.floor(Date.now() / 1000) + 86_400, key)}` }
        : {}),
    }, request);
  });
  app.get('/api/queue', { onRequest: authenticate }, async request => {
    const result = await infra.pool.query('SELECT state,count(*)::int AS count FROM jobs WHERE owner=$1 GROUP BY state', [subject(request)]);
    return contract(queueCounts, 'QueueCounts', { counts: result.rows }, request);
  });
  for (const route of ['/install/:id', '/api/install/:id', '/manifest/:id', '/download/:id', '/api/download/:id']) {
    app.get(route, async (request, reply) => {
      const { id } = z.object({ id: uuid }).parse(request.params);
      const { token } = z.object({ token: z.string().max(200) }).parse(request.query);
      if (!verifyCapability(id, token, key)) throw new APIError(404, 'Install link expired or invalid');
      const record = await infra.pool.query("SELECT result,output_key FROM jobs WHERE id=$1 AND kind='sign' AND state='completed'", [id]);
      const row = record.rows[0]; if (!row?.output_key) throw new APIError(404, 'Artifact not available');
      reply.header('Cache-Control', 'no-store');
      if (route.includes('/download/')) return reply.redirect(await infra.downloadLink(row.output_key));
      const metadata = artifactMetadata.parse(row.result);
      const manifestURL = `${config.PUBLIC_ORIGIN}/manifest/${id}?token=${encodeURIComponent(token)}`;
      if (route.includes('/manifest/')) return reply.type('application/xml').send(manifest(metadata, `${config.PUBLIC_ORIGIN}/download/${id}?token=${encodeURIComponent(token)}`));
      const link = installLink(manifestURL);
      return reply.type('text/html; charset=utf-8').send(installPage(metadata, link, await QRCode.toDataURL(link)));
    });
  }
  return app;
}
