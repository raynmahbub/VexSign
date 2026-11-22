import { Worker } from 'bullmq';
import { loadConfig } from '../../Configuration/config.js';
import { infrastructure } from '../../Storage/infrastructure.js';
import { PendingJobDispatcher } from '../JobQueue/dispatch.js';
import { deliverWebhooks, failureCode, finish, processJob, pruneWebhooks, type WorkerDeps } from './processor.js';

/**
 * Process entrypoint only: build the dependencies, start the worker and the repair poll, shut down
 * cleanly. The job pipeline itself lives in `processor.ts` so it can be tested with injected fakes;
 * importing this file connects to PostgreSQL, Redis and S3 and starts consuming, so nothing here is
 * loadable by a test. `API/main.ts` is the same shape for the HTTP side.
 *
 * The compiled path is pinned by `package.json`'s `worker` script and by
 * `VexSign/Tools/Validation/architecture-rules/test_repository_layout.py`.
 */
const config = loadConfig();
const infra = infrastructure(config);
const deps: WorkerDeps = { config, infra, key: Buffer.from(config.ENCRYPTION_KEY, 'hex') };

const worker = new Worker<{ id: string }>('vexsign-signing-v1', job => processJob(deps, job), {
  connection: infra.redis,
  concurrency: config.SIGNING_CONCURRENCY,
  lockDuration: 60_000,
  maxStalledCount: 2,
});
// A BullMQ or ioredis error can carry the connection string, so only its type is logged.
worker.on('error', error => {
  console.error(`Worker infrastructure error: ${failureCode(error)}`);
});

let polling = false;
const pendingDispatcher = new PendingJobDispatcher();
async function dispatch() {
  if (polling) return;
  polling = true;
  try {
    await pendingDispatcher.dispatch(infra, id => finish(deps, id, 'failed', null, null, null));
    await deliverWebhooks(deps);
    await pruneWebhooks(deps);
  } catch (error) {
    console.error(`Dispatch unavailable; retrying on next interval: ${failureCode(error)}`);
  } finally {
    polling = false;
  }
}

const timer = setInterval(() => {
  void dispatch();
}, 5000);
await dispatch();
let closing = false;
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.once(signal, () => {
    void (async () => {
      if (closing) return;
      closing = true;
      clearInterval(timer);
      await worker.close();
      while (polling) await new Promise(resolve => setTimeout(resolve, 50));
      await infra.close();
    })();
  });
}
