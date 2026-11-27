import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Buffer } from 'node:buffer';
import { verifyIpaSeal, parseXmlPlist, safeArchivePath } from '../Signing/Worker/ipaSeal.js';
import { buildZip, bundleEntries, ipaEntries, machO, codeResourcesPlist, type ZipEntry } from './support/sealedIpa.js';

const info = Buffer.from('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleName</key><string>A &amp; B</string></dict></plist>');
const sealed = { 'Info.plist': info, 'embedded.mobileprovision': Buffer.from('profile-bytes'), 'Assets/icon.png': Buffer.from('png') };

async function withIpa(entries: ZipEntry[], check: (path: string) => Promise<void>) {
  const dir = await mkdtemp(join(tmpdir(), 'ipa-seal-'));
  try {
    const path = join(dir, 'signed.ipa');
    await writeFile(path, buildZip(entries), { mode: 0o600 });
    await check(path);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

async function assertRejected(entries: ZipEntry[]) {
  await withIpa(entries, path => assert.rejects(verifyIpaSeal(path), /^Error: INVALID_OUTPUT$/));
}

test('a complete sealed IPA passes, with stored and deflated members', async () => {
  await withIpa(ipaEntries('Signed', sealed), path => verifyIpaSeal(path));
  await withIpa(ipaEntries('Signed', sealed, { method: 8 }), path => verifyIpaSeal(path));
});

test('an unsigned IPA (no CodeResources) is refused', async () => {
  const entries = ipaEntries('Signed', sealed).filter(e => !e.name.endsWith('CodeResources'));
  await assertRejected(entries);
});

test('a resource changed after sealing is refused', async () => {
  const entries = bundleEntries('Payload/Signed.app/', sealed, {
    executableName: 'Signed',
    sealedContents: { ...sealed, 'Info.plist': Buffer.from('tampered') },
  });
  await assertRejected([{ name: 'Payload/', directory: true }, ...entries]);
});

test('an unsealed resource added to the bundle is refused', async () => {
  await assertRejected(ipaEntries('Signed', sealed, {
    extra: [{ name: 'Payload/Signed.app/Resources/injected.dylib', data: machO() }],
  }));
  await assertRejected(ipaEntries('Signed', sealed, {
    extra: [{ name: 'Payload/Signed.app/config.json', data: Buffer.from('{}') }],
  }));
});

test('a file the seal explicitly omits is accepted; an unrelated unsealed file is still refused', async () => {
  const omit = ['.*\\.lproj/locversion\\.plist'];
  await withIpa(ipaEntries('Signed', sealed, {
    omitRules: omit,
    extra: [{ name: 'Payload/Signed.app/en.lproj/locversion.plist', data: Buffer.from('omitted') }],
  }), path => verifyIpaSeal(path));
  await assertRejected(ipaEntries('Signed', sealed, {
    omitRules: omit,
    extra: [{ name: 'Payload/Signed.app/en.lproj/Localizable.strings', data: Buffer.from('unsealed') }],
  }));
});

test('a second unsealed root executable is refused', async () => {
  await assertRejected(ipaEntries('Signed', sealed, {
    extra: [{ name: 'Payload/Signed.app/Helper', data: machO() }],
  }));
});

test('a bundle with no root executable is refused', async () => {
  await assertRejected(ipaEntries('Signed', sealed, { executable: Buffer.from('not a macho') }));
});

test('symlinks and traversal paths are refused before any extraction', async () => {
  await assertRejected([...ipaEntries('Signed', sealed), { name: 'Payload/Signed.app/link', symlinkTarget: '/etc/passwd' }]);
  await assertRejected([...ipaEntries('Signed', sealed), { name: 'Payload/../../escape', data: Buffer.from('x') }]);
  await assertRejected([...ipaEntries('Signed', sealed), { name: '/abs', data: Buffer.from('x') }]);
});

test('a file whose decoded bytes do not match the stored CRC is refused', async () => {
  const entries = ipaEntries('Signed', sealed).map(e => e.name === 'Payload/Signed.app/Info.plist' ? { ...e, badCrc: true } : e);
  await assertRejected(entries);
});

test('a sealed nested appex is verified, and tampering inside it is refused', async () => {
  const appexSealed = { 'Info.plist': Buffer.from('appex-info') };
  const nested = bundleEntries('Payload/Signed.app/PlugIns/Ext.appex/', appexSealed, { executableName: 'Ext' });
  await withIpa([...ipaEntries('Signed', sealed), ...nested], path => verifyIpaSeal(path));

  const tampered = bundleEntries('Payload/Signed.app/PlugIns/Ext.appex/', appexSealed, {
    executableName: 'Ext',
    sealedContents: { 'Info.plist': Buffer.from('changed') },
  });
  await assertRejected([...ipaEntries('Signed', sealed), ...tampered]);
});

test('a nested bundle without its own seal must be sealed by its parent', async () => {
  const resourceBundle = [
    { name: 'Payload/Signed.app/Strings.bundle/en.strings', data: Buffer.from('"a" = "b";') },
  ];
  await assertRejected(ipaEntries('Signed', sealed, { extra: resourceBundle }));
  const parentSealed = { ...sealed, 'Strings.bundle/en.strings': Buffer.from('"a" = "b";') };
  await withIpa(ipaEntries('Signed', parentSealed), path => verifyIpaSeal(path));
});

test('two app bundles in Payload are refused', async () => {
  await assertRejected([...ipaEntries('Signed', sealed), ...bundleEntries('Payload/Other.app/', sealed, { executableName: 'Other' })]);
});

test('XML plist parsing decodes entities and rejects malformed input', () => {
  const parsed = parseXmlPlist('<?xml version="1.0"?><plist><dict><key>a</key><string>x &amp; &lt;y&gt;</string>' +
    '<key>b</key><array><true/><integer>3</integer></array><key>c</key><data>AQI=</data></dict></plist>') as Record<string, unknown>;
  assert.equal(parsed.a, 'x & <y>');
  assert.deepEqual(parsed.b, [true, 3]);
  assert.deepEqual(parsed.c, Buffer.from([1, 2]));
  assert.throws(() => parseXmlPlist('<plist><dict><key>a</key></dict></plist>'), /INVALID_OUTPUT/);
  assert.throws(() => parseXmlPlist('<plist><dict><key>a</key><string>1</string><key>a</key><string>2</string></dict></plist>'), /INVALID_OUTPUT/);
  assert.throws(() => parseXmlPlist('<plist><dict></plist>'), /INVALID_OUTPUT/);
});

test('the seal generator round-trips through the parser', () => {
  const xml = codeResourcesPlist({ 'Info.plist': Buffer.from('x') });
  const parsed = parseXmlPlist(xml) as { files2: Record<string, { hash2: Buffer }> };
  assert.equal(parsed.files2['Info.plist']?.hash2.length, 32);
});

test('safeArchivePath accepts bundle paths and rejects escapes', () => {
  safeArchivePath('Payload/A.app/Info.plist');
  for (const bad of ['../x', 'a/../../b', '/abs', 'a\\b', 'a//b', 'a\0b', '']) {
    assert.throws(() => safeArchivePath(bad), /INVALID_OUTPUT/, bad);
  }
});
