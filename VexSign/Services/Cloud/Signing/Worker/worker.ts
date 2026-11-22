import { Worker } from 'bullmq';
import { loadConfig } from '../../Configuration/config.js';
import { infrastructure } from '../../Storage/infrastructure.js';
import { PendingJobDispatcher } from '../JobQueue/dispatch.js';
import { createWorkerRuntime } from './processor.js';

const config = loadConfig();
const infra = infrastructure(config);
const key = Buffer.from(config.ENCRYPTION_KEY, 'hex');
const runtime = createWorkerRuntime(config, infra, key);

const worker = new Worker('vexsign-signing-v1', runtime.processJob, {
  connection: infra.redis,
  concurrency: config.SIGNING_CONCURRENCY,
  lockDuration: 60_000,
  maxStalledCount: 2,
});
worker.on('error', () => { console.error('Worker infrastructure error'); });

let polling = false;
const pendingDispatcher = new PendingJobDispatcher();
async function dispatch() {
  if (polling) return;
  polling = true;
  try {
    await pendingDispatcher.dispatch(infra, id => runtime.finish(id, 'failed', null, null, null));
    await runtime.deliverWebhooks();
  } catch {
    console.error('Dispatch unavailable; retrying on next interval');
  } finally {
    polling = false;
  }
}

const timer = setInterval(() => { void dispatch(); }, 5000);
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
