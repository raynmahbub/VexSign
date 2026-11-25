import { loadConfig } from '../Configuration/config.js';
import { infrastructure } from '../Storage/infrastructure.js';
import { buildApp } from './Routes/app.js';
const config = loadConfig();
const infra = infrastructure(config);
const app = await buildApp(config, infra);
app.addHook('onClose', async () => { await infra.close(); });
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { void app.close(); });
await app.listen({ port: config.PORT, host: '0.0.0.0' });
