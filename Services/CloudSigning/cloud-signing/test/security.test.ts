import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { seal, unseal, capability, verifyCapability, escapeMarkup, permittedWebhook } from '../src/security.js';
import { artifactMetadata, signRequest, batchRequest } from '../src/contracts.js';
import { installLink, installPage, manifest } from '../src/ota.js';
import { signerResult, invokeSigner } from '../src/signer.js';

test('password envelope is randomized, authenticated, and bound to its job', () => {
  const key = randomBytes(32); const sealed = seal('private password', key, 'job-a');
  assert.equal(unseal(sealed, key, 'job-a'), 'private password');
  assert.notEqual(sealed, seal('private password', key, 'job-a'));
  assert.throws(() => unseal(sealed, key, 'job-b'));
  assert.throws(() => unseal(sealed, randomBytes(32), 'job-a'));
  const bytes = Buffer.from(sealed, 'base64'); bytes[bytes.length - 1]! ^= 1;
  assert.throws(() => unseal(bytes.toString('base64'), key, 'job-a'));
  assert.throws(() => unseal('AA==', key, 'job-a'));
});
test('OTA capabilities expire, are resource-scoped, and reject malformed input', () => {
  const now = 1_790_000_000_000; const key = randomBytes(32);
  const token = capability('a', Math.floor(now / 1000) + 60, key);
  assert.ok(verifyCapability('a', token, key, now));
  assert.equal(verifyCapability('b', token, key, now), false);
  assert.equal(verifyCapability('a', token, key, now + 60_000), false);
  for (const invalid of ['', 'NaN.x', `${token}.x`, '9999999999.fake', token + 'a']) assert.equal(verifyCapability('a', invalid, key, now), false);
});
test('webhooks require exact administrator registration and HTTPS', () => {
  const allowlist = 'https://hooks.example.test/signing';
  assert.ok(permittedWebhook(allowlist, allowlist));
  assert.ok(permittedWebhook(undefined, allowlist));
  for (const url of ['http://hooks.example.test/signing', 'https://hooks.example.test.evil/signing', 'https://hooks.example.test/signing?redirect=http://127.0.0.1', 'https://user:pass@hooks.example.test/signing', 'https://hooks.example.test/signing#x', 'http://169.254.169.254/']) assert.equal(permittedWebhook(url, allowlist), false);
});
const metadata = artifactMetadata.parse({ name: '<script>alert("X")</script> & app', bundleIdentifier: 'com.test.app', version: '1.0', changelog: '<img onerror=alert(1)>' });
test('OTA manifests and pages escape untrusted metadata and preserve query strings', () => {
  const url = 'https://example.test/manifest/a?token=a&x=2';
  const link = installLink(url);
  assert.equal(new URL(link).searchParams.get('url'), url);
  const xml = manifest(metadata, 'https://example.test/download/a?token=a&x=2');
  assert.ok(xml.includes('software-package')); assert.ok(xml.includes('bundle-identifier'));
  assert.ok(xml.includes('&amp;x=2')); assert.ok(!xml.includes('<script>'));
  const page = installPage(metadata, link, 'data:image/png;base64,AA==');
  assert.ok(!page.includes('<script>')); assert.ok(!page.includes('<img onerror='));
  assert.ok(page.includes('&lt;script&gt;'));
  assert.throws(() => manifest(metadata, 'http://example.test/a'));
  assert.equal(escapeMarkup(`&<>"'`), '&amp;&lt;&gt;&quot;&#39;');
});
test('contracts reject shell arguments, arbitrary signing paths, oversized batches and unsigned receipts', () => {
  assert.equal(signRequest.safeParse({ ipaId: '../x', p12Id: 'x', provisionId: 'x', password: 'x', command: 'sh' }).success, false);
  assert.equal(batchRequest.safeParse({ jobs: [] }).success, false);
  assert.equal(signerResult.safeParse({ kind: 'sign', signatureVerified: false, metadata }).success, false);
  assert.equal(signerResult.safeParse({ kind: 'sign', signatureVerified: true, metadata }).success, true);
});
test('missing signer fails instead of returning a simulated artifact', async () => {
  await assert.rejects(invokeSigner('/nonexistent-vexsign-test-engine', { protocolVersion: 1, kind: 'sign', directory: '/tmp', p12Path: '/tmp/a', provisionPath: '/tmp/b', outputPath: '/tmp/c', password: 'not-logged' }), /SIGNER_FAILED/);
});
