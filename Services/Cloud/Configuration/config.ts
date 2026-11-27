import { readFileSync, statSync, realpathSync } from 'node:fs';
import { z } from 'zod';

/**
 * The repository ships `Examples/mock-signer.mjs` as a protocol fixture. It never signs. A deployment that
 * points the worker at it would complete every job, so refuse it, and refuse anything that is not an
 * executable regular file at the time the configuration loads.
 */
export function isProductionSigner(path: string): boolean {
  let resolved: string;
  try { resolved = realpathSync(path); } catch { return false; }
  if (/(^|\/)mock-signer(\.[a-z]+)?$/i.test(resolved) || /\/Examples\//.test(resolved)) return false;
  try {
    const stat = statSync(resolved);
    return stat.isFile() && (stat.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

const schema = z.object({
  DATABASE_URL: z.string().min(1), REDIS_URL: z.url(),
  S3_ENDPOINT: z.url().refine(v => new URL(v).protocol === 'https:', 'S3 must use TLS'),
  S3_REGION: z.string().default('us-east-1'), S3_BUCKET: z.string().min(1),
  S3_KMS_KEY_ID: z.string().optional(),
  PUBLIC_ORIGIN: z.url().refine(v => { const u = new URL(v); return u.protocol === 'https:' && u.pathname === '/' && !u.search && !u.hash && !u.username && !u.password; }, 'Use a bare HTTPS origin'),
  JWT_PUBLIC_KEY_FILE: z.string().min(1), JWT_ISSUER: z.string().min(1), JWT_AUDIENCE: z.string().min(1),
  ENCRYPTION_KEY: z.string().regex(/^[a-fA-F0-9]{64}$/),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  SIGNER_EXECUTABLE: z.string().startsWith('/'),
  SIGNING_CONCURRENCY: z.coerce.number().int().min(1).max(8).default(2),
  WEBHOOK_ALLOWLIST: z.string().default(''),
  TRUSTED_PROXIES: z.string().default(''),
});
export type Config = z.infer<typeof schema> & { jwtPublicKey: string };
/** Only the worker runs the launcher, so only the worker requires a real one. The API still loads without it. */
export function assertWorkerSigner(config: Config): void {
  if (!isProductionSigner(config.SIGNER_EXECUTABLE)) {
    throw new Error('SIGNER_EXECUTABLE must name the operator\'s executable signing launcher, not the non-signing example');
  }
}

export function loadConfig(): Config {
  const config = schema.parse(process.env);
  return { ...config, PUBLIC_ORIGIN: new URL(config.PUBLIC_ORIGIN).origin, jwtPublicKey: readFileSync(config.JWT_PUBLIC_KEY_FILE, 'utf8') };
}
