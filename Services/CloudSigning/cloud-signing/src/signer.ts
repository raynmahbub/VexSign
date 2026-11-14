import { spawn } from 'node:child_process';
import { z } from 'zod';
import { artifactMetadata, certificateResult } from './contracts.js';

export const signerResult = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('sign'), signatureVerified: z.literal(true), metadata: artifactMetadata }).strict(),
  z.object({ kind: z.literal('check-cert'), certificate: certificateResult }).strict(),
]);
export type SignerInput = {
  protocolVersion: 1; kind: 'sign' | 'check-cert'; directory: string;
  ipaPath?: string; p12Path: string; provisionPath: string; outputPath: string; password: string;
};
/** Administrator-provided sandbox launcher, not a shell command supplied by clients.
 * The launcher MUST isolate archive extraction and enforce resource limits. Secrets
 * are delivered over stdin, never argv, environment, Redis payloads, or logs.
 */
export function invokeSigner(executable: string, input: SignerInput): Promise<z.infer<typeof signerResult>> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, [], {
      cwd: input.directory, detached: true, shell: false,
      stdio: ['pipe', 'pipe', 'ignore'],
      env: { PATH: '/usr/local/bin:/usr/bin:/bin', LANG: 'C.UTF-8', HOME: input.directory, TMPDIR: input.directory },
    });
    const output: Buffer[] = []; let size = 0; let settled = false;
    function kill() { if (child.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch { /* Already exited. */ } } }
    function fail() {
      if (settled) return; settled = true; clearTimeout(timer); kill();
      reject(new Error('SIGNER_FAILED'));
    }
    const timer = setTimeout(fail, 10 * 60_000);
    child.on('error', fail); child.stdin.on('error', fail);
    child.stdout.on('data', (data: Buffer) => { size += data.length; if (size > 1024 ** 2) fail(); else output.push(data); });
    child.on('close', code => {
      if (settled) return;
      if (code !== 0) { fail(); return; }
      clearTimeout(timer); settled = true; kill();
      try {
        const result = signerResult.parse(JSON.parse(Buffer.concat(output).toString('utf8')));
        if (result.kind !== input.kind) throw new Error('Mismatched operation');
        resolve(result);
      } catch { reject(new Error('INVALID_SIGNER_RESULT')); }
    });
    child.stdin.end(JSON.stringify(input));
  });
}
