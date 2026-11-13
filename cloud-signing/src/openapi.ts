import { writeFile } from 'node:fs/promises';
import { z } from 'zod';
import { signRequest, checkRequest, batchRequest, artifactMetadata, certificateResult, jobView, queueCounts } from './contracts.js';
const jsonBody = (ref: string) => ({ required: true, content: { 'application/json': { schema: { $ref: `#/components/schemas/${ref}` } } } });
const errors = Object.fromEntries([400, 401, 403, 404, 409, 413, 429, 500].map(code => [String(code), { description: 'Request rejected or service unavailable', content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } } }]));
const accepted = { '202': { description: 'Durably accepted; poll GET /api/jobs/{id}', content: { 'application/json': { schema: { $ref: '#/components/schemas/JobAccepted' } } } }, ...errors };
const id = { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } };
const token = { name: 'token', in: 'query', required: true, schema: { type: 'string' }, description: 'Expiring capability returned by an authenticated job-status request. Do not log or forward.' };
const idempotency = { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', format: 'uuid' } };
const paths: Record<string, unknown> = {
  '/api/upload': { post: { summary: 'Upload exactly one private IPA, P12, or provisioning profile', parameters: [{ name: 'kind', in: 'query', required: true, schema: { type: 'string', enum: ['ipa', 'p12', 'provision'] } }], requestBody: { required: true, content: { 'multipart/form-data': { schema: { type: 'object', required: ['file'], properties: { file: { type: 'string', format: 'binary' } }, additionalProperties: false } } } }, responses: { '201': { description: 'Private asset registered', content: { 'application/json': { schema: { type: 'object', required: ['id', 'kind', 'bytes', 'sha256'], properties: { id: { type: 'string', format: 'uuid' }, kind: { type: 'string' }, bytes: { type: 'integer' }, sha256: { type: 'string' } } } } } }, ...errors } } },
  '/api/sign': { post: { summary: 'Queue signing', parameters: [idempotency], requestBody: jsonBody('SignRequest'), responses: accepted } },
  '/api/check-cert': { post: { summary: 'Queue certificate inspection by the configured engine', parameters: [idempotency], requestBody: jsonBody('CheckRequest'), responses: accepted } },
  '/api/sign/batch': { post: { summary: 'Atomically queue up to 20 jobs (per-item idempotency keys)', requestBody: jsonBody('BatchRequest'), responses: { '202': { description: 'Accepted jobs', content: { 'application/json': { schema: { type: 'object', properties: { jobs: { type: 'array', items: { $ref: '#/components/schemas/JobAccepted' } } } } } } }, ...errors } } },
  '/api/jobs/{id}': { get: { summary: 'Tenant-scoped job status; completed signing includes a 24-hour installURL', parameters: [id], responses: { '200': { description: 'Job state, metadata or certificate result, error_code, output digest, and timestamps', content: { 'application/json': { schema: { $ref: '#/components/schemas/JobView' } } } }, ...errors } } },
  '/api/queue': { get: { summary: 'Counts of this tenant’s jobs grouped by state', responses: { '200': { description: 'This tenant only; every state is enumerable', content: { 'application/json': { schema: { $ref: '#/components/schemas/QueueCounts' } } } }, ...errors } } },
};
for (const route of ['/install/{id}', '/api/install/{id}', '/manifest/{id}', '/download/{id}', '/api/download/{id}']) {
  paths[route] = { get: { security: [], summary: route.includes('download') ? 'Redirect to a short-lived private S3 URL' : route.includes('manifest') ? 'iOS OTA plist' : 'Install page with QR and copy-link button', parameters: [id, token], responses: { [route.includes('download') ? '302' : '200']: { description: 'Capability-authorized response; Cache-Control: no-store' }, ...errors } } };
}
const schema = (value: z.ZodType) => z.toJSONSchema(value);
const document = {
  openapi: '3.1.0', info: { title: 'VexSign Cloud Signing', version: '0.1.0', description: 'JWT RS256 issued by your identity provider; scope signing:write; token lifetime <= 1 hour. HTTPS only at the edge. Existing Python premium API is separate.' },
  servers: [{ url: 'https://signing.example.com' }], security: [{ bearerAuth: [] }], paths,
  components: { securitySchemes: { bearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' } }, schemas: {
    SignRequest: schema(signRequest), CheckRequest: schema(checkRequest), BatchRequest: schema(batchRequest), ArtifactMetadata: schema(artifactMetadata), CertificateResult: schema(certificateResult),
    JobAccepted: { type: 'object', required: ['id', 'state'], properties: { id: { type: 'string', format: 'uuid' }, state: { type: 'string', enum: ['queued', 'running', 'completed', 'failed'] } } },
    JobView: schema(jobView), QueueCounts: schema(queueCounts),
    Error: { type: 'object', properties: { error: { type: 'string' }, requestId: { type: 'string' } } },
  } },
};
await writeFile('openapi.json', JSON.stringify(document, null, 2) + '\n');
