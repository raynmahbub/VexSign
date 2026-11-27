// Test-only builders for IPA archives. Not used at runtime.
import { createHash } from 'node:crypto';
import { crc32, deflateRawSync } from 'node:zlib';

export type ZipEntry = {
  name: string;
  data?: Buffer;
  method?: 0 | 8;
  directory?: boolean;
  symlinkTarget?: string;
  /** Test-only: store a CRC that does not match the bytes. */
  badCrc?: boolean;
};

const FILE_MODE = 0o100644 << 16;
const DIR_MODE = 0o040755 << 16;
const LINK_MODE = 0o120777 << 16;

/** A minimal ZIP writer: local headers, central directory, EOCD. Stored or deflated entries only. */
export function buildZip(entries: ZipEntry[]): Buffer {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'utf8');
    const raw = entry.symlinkTarget !== undefined ? Buffer.from(entry.symlinkTarget)
      : entry.directory ? Buffer.alloc(0) : entry.data ?? Buffer.alloc(0);
    const method = entry.directory || entry.symlinkTarget !== undefined ? 0 : entry.method ?? 0;
    const body = method === 8 ? deflateRawSync(raw) : raw;
    const crc = entry.badCrc ? (crc32(raw) ^ 1) >>> 0 : crc32(raw);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(0x21, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(body.length, 18);
    local.writeUInt32LE(raw.length, 22);
    local.writeUInt16LE(name.length, 26);
    locals.push(local, name, body);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(0x031e, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(method, 10);
    central.writeUInt16LE(0x21, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(body.length, 20);
    central.writeUInt32LE(raw.length, 24);
    central.writeUInt16LE(name.length, 28);
    const mode = entry.symlinkTarget !== undefined ? LINK_MODE : entry.directory ? DIR_MODE : FILE_MODE;
    central.writeUInt32LE(mode >>> 0, 38);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, name);

    offset += local.length + name.length + body.length;
  }
  const cd = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(cd.length, 12);
  eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, eocd]);
}

/** A fake but structurally valid Mach-O header: 64-bit little-endian magic plus padding. */
export function machO(): Buffer {
  const bytes = Buffer.alloc(64);
  bytes.writeUInt32LE(0xfeedfacf, 0);
  return bytes;
}

function sha(algorithm: 'sha1' | 'sha256', data: Buffer): Buffer {
  return createHash(algorithm).update(data).digest();
}

/** CodeResources (v2) sealing exactly `sealed`. Paths are bundle-relative. */
export function codeResourcesPlist(sealed: Record<string, Buffer>, omitRules: string[] = []): string {
  const files2 = Object.entries(sealed).map(([path, data]) =>
    `<key>${path}</key><dict><key>hash</key><data>${sha('sha1', data).toString('base64')}</data>` +
    `<key>hash2</key><data>${sha('sha256', data).toString('base64')}</data></dict>`).join('');
  return '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
    `<plist version="1.0"><dict><key>files</key><dict/><key>files2</key><dict>${files2}</dict>` +
    `<key>rules2</key><dict>${omitRules.map(p => `<key>${p}</key><dict><key>omit</key><true/></dict>`).join('')}</dict>` +
    '</dict></plist>\n';
}

/**
 * Entries for one sealed bundle rooted at `root` (ends with '/'). `sealed` is what the seal covers;
 * `executable` is the unsealed root Mach-O. Pass `extra` for files added after sealing.
 */
export function bundleEntries(root: string, sealed: Record<string, Buffer>, options: {
  executableName?: string; executable?: Buffer; extra?: ZipEntry[]; method?: 0 | 8;
  sealedContents?: Record<string, Buffer>; omitRules?: string[];
} = {}): ZipEntry[] {
  const method = options.method ?? 0;
  const contents = options.sealedContents ?? sealed;
  const entries: ZipEntry[] = [
    { name: root, directory: true },
    { name: `${root}${options.executableName ?? 'App'}`, data: options.executable ?? machO(), method },
    { name: `${root}_CodeSignature/`, directory: true },
    { name: `${root}_CodeSignature/CodeResources`, data: Buffer.from(codeResourcesPlist(sealed, options.omitRules)), method },
  ];
  for (const [path, data] of Object.entries(contents)) entries.push({ name: root + path, data, method });
  return [...entries, ...(options.extra ?? [])];
}

/** A complete app IPA: Payload/<name>.app/ with its own seal. */
export function ipaEntries(appName: string, sealed: Record<string, Buffer>, options: Parameters<typeof bundleEntries>[2] = {}): ZipEntry[] {
  return [
    { name: 'Payload/', directory: true },
    ...bundleEntries(`Payload/${appName}.app/`, sealed, { executableName: appName, ...options }),
  ];
}
