import pg from 'pg';
import { Redis } from 'ioredis';
import { Queue } from 'bullmq';
import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { Config } from './config.js';

export function infrastructure(config: Config) {
  const pool = new pg.Pool({ connectionString: config.DATABASE_URL, max: 12, statement_timeout: 30_000 });
  const redis = new Redis(config.REDIS_URL, { maxRetriesPerRequest: null });
  const queue = new Queue('vexsign-signing-v1', { connection: redis });
  const s3 = new S3Client({ endpoint: config.S3_ENDPOINT, region: config.S3_REGION, forcePathStyle: true });
  const encryption = config.S3_KMS_KEY_ID
    ? { ServerSideEncryption: 'aws:kms' as const, SSEKMSKeyId: config.S3_KMS_KEY_ID }
    : { ServerSideEncryption: 'AES256' as const };
  async function downloadLink(key: string) {
    return getSignedUrl(s3, new GetObjectCommand({ Bucket: config.S3_BUCKET, Key: key, ResponseContentType: 'application/octet-stream' }), { expiresIn: 120 });
  }
  async function close() { await queue.close(); await redis.quit(); await pool.end(); s3.destroy(); }
  return { pool, redis, queue, s3, encryption, downloadLink, close };
}
export type Infrastructure = ReturnType<typeof infrastructure>;
