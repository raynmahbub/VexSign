import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isProductionSigner } from '../Configuration/config.js';

test('the repository mock launcher is never accepted as the production signer', () => {
  const mock = new URL('../Examples/mock-signer.mjs', import.meta.url).pathname;
  assert.equal(isProductionSigner(mock), false);
});

test('missing, non-executable and mock-named launchers are refused; an executable launcher is accepted', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'signer-config-'));
  try {
    assert.equal(isProductionSigner(join(dir, 'absent')), false);

    const plain = join(dir, 'launcher');
    await writeFile(plain, '#!/bin/sh\n');
    assert.equal(isProductionSigner(plain), false, 'not executable');

    await chmod(plain, 0o755);
    assert.equal(isProductionSigner(plain), true, 'executable real launcher');

    const named = join(dir, 'mock-signer');
    await writeFile(named, '#!/bin/sh\n');
    await chmod(named, 0o755);
    assert.equal(isProductionSigner(named), false, 'mock-named launcher');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
