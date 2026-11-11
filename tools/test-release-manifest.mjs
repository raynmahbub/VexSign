import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  createManifest,
  createSignedEnvelope,
  validateManifestPayload,
} from './sign-release-manifest.mjs';

const { privateKey, publicKey } = generateKeyPairSync('ed25519');
const privateKeyPEM = privateKey.export({ type: 'pkcs8', format: 'pem' });
const publicKeyPEM = publicKey.export({ type: 'spki', format: 'pem' });

function validManifest(overrides = {}) {
  const now = Date.now();
  const isoSeconds = (timestamp) => new Date(timestamp).toISOString().replace(/\.\d{3}Z$/, 'Z');
  return {
    schemaVersion: 1,
    applicationIdentifier: 'com.vexsign.app',
    version: '1.2.3-beta.1',
    buildNumber: '1020304',
    channel: 'beta',
    minimumOSVersion: '17.0',
    downloadURL: 'https://downloads.example.test/VexSign.ipa',
    ipaSHA256: 'a'.repeat(64),
    releaseNotesURL: 'https://github.com/raynmahbub/VexSign/releases',
    createdAt: isoSeconds(now - 60_000),
    expiresAt: isoSeconds(now + 86_400_000),
    signing: {
      distributionMethod: 'artifactDownload',
      signingClass: 'unsigned',
      teamIdentifier: null,
      certificateSHA256: null,
    },
    ...overrides,
  };
}

test('creates an Ed25519 envelope that verifies over the exact payload bytes', () => {
  const envelope = createSignedEnvelope(validManifest(), privateKeyPEM, 'release-v1');
  assert.equal(envelope.algorithm, 'Ed25519');
  assert.equal(envelope.keyID, 'release-v1');
  const payload = Buffer.from(envelope.payloadBase64, 'base64');
  const signature = Buffer.from(envelope.signatureBase64, 'base64');
  assert.equal(verify(null, payload, publicKeyPEM, signature), true);
  assert.equal(JSON.parse(payload.toString('utf8')).applicationIdentifier, 'com.vexsign.app');
});

test('refuses insecure URLs, expired metadata, invalid hashes and signing-class substitution', () => {
  assert.throws(() => validateManifestPayload(validManifest({ downloadURL: 'http://bad.example/app.ipa' })));
  assert.throws(() => validateManifestPayload(validManifest({ ipaSHA256: 'xyz' })));
  assert.throws(() => validateManifestPayload(validManifest({ expiresAt: new Date(Date.now() - 1_000).toISOString() })));
  assert.throws(() => validateManifestPayload(validManifest({ expiresAt: new Date(Date.now() + 100 * 86_400_000).toISOString() })));
  assert.throws(() => validateManifestPayload(validManifest({
    signing: { distributionMethod: 'adHoc', signingClass: 'appStore' },
  })));
  assert.throws(() => validateManifestPayload(validManifest({
    signing: { distributionMethod: 'artifactDownload', signingClass: 'unsigned', teamIdentifier: 'bad' },
  })));
  assert.throws(() => createSignedEnvelope(validManifest(), privateKeyPEM, 'bad/key'));
  assert.throws(() => createSignedEnvelope(validManifest({
    signing: { distributionMethod: 'directOTA', signingClass: 'adHoc' },
  }), privateKeyPEM, 'release-v1'), /download-only unsigned artifacts/);
});

test('hashes the artifact and atomically publishes a non-overwritable manifest', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'vexsign-release-manifest-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const artifactPath = join(directory, 'VexSign.ipa');
  const outputPath = join(directory, 'release', 'manifest.json');
  await writeFile(artifactPath, Buffer.from('artifact bytes'));
  const inputs = {
    artifactPath,
    outputPath,
    privateKeyPEM,
    keyID: 'release-v1',
    metadata: {
      applicationIdentifier: 'com.vexsign.app',
      version: '1.2.3',
      buildNumber: '1020304',
      channel: 'stable',
      minimumOSVersion: '17.0',
      downloadURL: 'https://downloads.example.test/VexSign.ipa',
      releaseNotesURL: 'https://github.com/raynmahbub/VexSign/releases',
      expirySeconds: 3600,
      distributionMethod: 'artifactDownload',
      signingClass: 'unsigned',
    },
  };
  await createManifest(inputs);
  const envelope = JSON.parse(await readFile(outputPath, 'utf8'));
  const payloadBytes = Buffer.from(envelope.payloadBase64, 'base64');
  const payload = JSON.parse(payloadBytes.toString('utf8'));
  assert.equal(payload.ipaSHA256, '4659fc0570122b0e0aa14f4ff7c261b1fe51795a01ba79963f462ebf40d7520d');
  assert.equal(payload.signing.distributionMethod, 'artifactDownload');
  assert.equal(verify(null, payloadBytes, publicKeyPEM, Buffer.from(envelope.signatureBase64, 'base64')), true);
  await assert.rejects(createManifest(inputs));
});
