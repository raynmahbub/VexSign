import test from 'node:test';
import assert from 'node:assert/strict';
import type { Config } from '../Configuration/config.js';
import { infrastructure } from '../Storage/infrastructure.js';

test('API Redis operations fail promptly when Redis is unavailable', async () => {
  // A reserved invalid hostname fails DNS; no production infrastructure is contacted.
  const infra = infrastructure({ REDIS_URL: 'redis://unavailable.invalid:6379',
    S3_ENDPOINT: 'https://storage.invalid', S3_REGION: 'test' } as Config);
  try {
    assert.equal(infra.redis.options.enableOfflineQueue, false);
    assert.equal(infra.redis.options.commandTimeout, 5000);
    assert.equal(infra.redis.options.maxRetriesPerRequest, 1);
    const start = Date.now();
    await assert.rejects(infra.redis.ping());
    assert.ok(Date.now() - start < 6000);
  } finally {
    await infra.queue.close(); infra.redis.disconnect(); await infra.pool.end(); infra.s3.destroy();
  }
});
