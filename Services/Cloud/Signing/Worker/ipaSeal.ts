// Independent structural check of a signed IPA produced by the operator's launcher.
//
// The launcher's `signatureVerified: true` is a claim, not evidence. This module checks what can be
// checked without Apple's trust store: that the archive is well-formed and safe to extract, that
// every app file is listed in the bundle's own `_CodeSignature/CodeResources` seal with matching
// SHA-1 and SHA-256 digests, that nothing unsealed is hidden in the bundle, and that every nested
// bundle that carries its own seal is checked the same way.
//
// It does NOT verify the CMS signature or the certificate chain. Those need Apple's roots and a
// Security/OpenSSL CMS verifier, which is the launcher's job (see Docs/Audit/signing-to-installation-audit-2026-11-27.md,
// F-1). A launcher that produced a seal over the wrong bytes is caught here; a launcher that produced
// a well-sealed bundle with a forged signature is not.
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { open, type FileHandle } from 'node:fs/promises';
import { createInflateRaw, crc32 } from 'node:zlib';
import { pipeline } from 'node:stream/promises';

export type SealLimits = {
  maxEntries: number;
  maxCentralDirectoryBytes: number;
  maxEntryBytes: number;
  maxTotalBytes: number;
  maxSealedFileBytes: number;
};

export const DEFAULT_SEAL_LIMITS: SealLimits = {
  maxEntries: 50_000,
  maxCentralDirectoryBytes: 64 * 1024 ** 2,
  maxEntryBytes: 2 * 1024 ** 3,
  maxTotalBytes: 4 * 1024 ** 3,
  maxSealedFileBytes: 1024 ** 2,
};

// Every failure is the fixed sentinel the worker already maps to a job error code.
function invalid(): never {
  throw new Error('INVALID_OUTPUT');
}

const CENTRAL = 0x02014b50;
const LOCAL = 0x04034b50;
const EOCD = 0x06054b50;
const MACHO_MAGIC = new Set(['feedface', 'feedfacf', 'cafebabe', 'cefaedfe', 'cffaedfe', 'bebafeca']);
const NESTED_BUNDLE = /\.(appex|framework|bundle|app|xctest)$/;

type Entry = {
  name: string;
  method: number;
  flags: number;
  crc: number;
  compressed: number;
  size: number;
  offset: number;
  isDirectory: boolean;
};

type Digest = { sha1: string; sha256: string; head: string; size: number };

/** Rejects any archive path that could escape the extraction directory or name a device path. */
export function safeArchivePath(name: string): void {
  if (name.length === 0 || name.length > 1024 || name.includes('\\') || name.includes('\0')) invalid();
  if (name.startsWith('/') || /^[A-Za-z]:/.test(name)) invalid();
  for (const part of name.replace(/\/$/, '').split('/')) {
    if (part === '..' || part === '.' || part === '') invalid();
  }
}

export function parseCentralDirectory(cd: Buffer, count: number): Entry[] {
  const entries: Entry[] = [];
  const seen = new Set<string>();
  let pos = 0;
  for (let i = 0; i < count; i++) {
    if (pos + 46 > cd.length || cd.readUInt32LE(pos) !== CENTRAL) invalid();
    const flags = cd.readUInt16LE(pos + 8);
    const method = cd.readUInt16LE(pos + 10);
    const crc = cd.readUInt32LE(pos + 16);
    const compressed = cd.readUInt32LE(pos + 20);
    const size = cd.readUInt32LE(pos + 24);
    const nameLength = cd.readUInt16LE(pos + 28);
    const extraLength = cd.readUInt16LE(pos + 30);
    const commentLength = cd.readUInt16LE(pos + 32);
    const externalAttributes = cd.readUInt32LE(pos + 38);
    const offset = cd.readUInt32LE(pos + 42);
    const end = pos + 46 + nameLength + extraLength + commentLength;
    if (end > cd.length) invalid();
    // Encrypted entries cannot be sealed-checked; zip64 is refused to keep the offsets exact.
    if (flags & 0x1 || flags & 0x40) invalid();
    if (method !== 0 && method !== 8) invalid();
    if (compressed === 0xffffffff || size === 0xffffffff || offset === 0xffffffff) invalid();
    // Unix file type in the high 16 bits: symlinks and devices are never legitimate IPA content.
    const unixType = (externalAttributes >>> 16) & 0o170000;
    if (unixType !== 0 && unixType !== 0o100000 && unixType !== 0o040000) invalid();
    const name = cd.toString('utf8', pos + 46, pos + 46 + nameLength);
    safeArchivePath(name);
    if (seen.has(name)) invalid();
    seen.add(name);
    entries.push({
      name, method, flags, crc, compressed, size, offset,
      isDirectory: name.endsWith('/') || unixType === 0o040000,
    });
    pos = end;
  }
  if (pos !== cd.length) invalid();
  return entries;
}

async function readAt(handle: FileHandle, length: number, position: number): Promise<Buffer> {
  const buffer = Buffer.alloc(length);
  const { bytesRead } = await handle.read(buffer, 0, length, position);
  if (bytesRead !== length) invalid();
  return buffer;
}

async function readEntries(handle: FileHandle, fileSize: number, limits: SealLimits): Promise<Entry[]> {
  const tailLength = Math.min(fileSize, 22 + 0xffff);
  const tail = await readAt(handle, tailLength, fileSize - tailLength);
  let eocd = -1;
  for (let i = tail.length - 22; i >= 0; i--) {
    if (tail.readUInt32LE(i) === EOCD) { eocd = i; break; }
  }
  if (eocd < 0) invalid();
  const count = tail.readUInt16LE(eocd + 10);
  const cdSize = tail.readUInt32LE(eocd + 12);
  const cdOffset = tail.readUInt32LE(eocd + 16);
  if (count === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) invalid();
  if (count === 0 || count > limits.maxEntries) invalid();
  if (cdSize > limits.maxCentralDirectoryBytes || cdOffset + cdSize > fileSize) invalid();
  const cd = await readAt(handle, cdSize, cdOffset);
  return parseCentralDirectory(cd, count);
}

/** Streams one entry, checking its declared size and CRC against the decoded bytes. */
async function digestEntry(
  path: string, handle: FileHandle, entry: Entry, limits: SealLimits, keep = false,
): Promise<Digest & { bytes?: Buffer }> {
  if (entry.size > limits.maxEntryBytes) invalid();
  const header = await readAt(handle, 30, entry.offset);
  if (header.readUInt32LE(0) !== LOCAL) invalid();
  const nameLength = header.readUInt16LE(26);
  const extraLength = header.readUInt16LE(28);
  const dataStart = entry.offset + 30 + nameLength + extraLength;
  if (keep && entry.size > limits.maxSealedFileBytes) invalid();
  if (entry.compressed === 0 && entry.size === 0) {
    return {
      sha1: createHash('sha1').digest('hex'), sha256: createHash('sha256').digest('hex'), head: '', size: 0,
      bytes: keep ? Buffer.alloc(0) : undefined,
    };
  }
  if (entry.compressed === 0) invalid();

  const sha1 = createHash('sha1');
  const sha256 = createHash('sha256');
  let size = 0;
  let crc = 0;
  let head = Buffer.alloc(0);
  const kept: Buffer[] = [];
  const consume = async (source: AsyncIterable<Buffer>) => {
    for await (const chunk of source) {
      size += chunk.length;
      if (size > entry.size) invalid();
      if (head.length < 4) head = Buffer.concat([head, chunk.subarray(0, 4 - head.length)]);
      sha1.update(chunk);
      sha256.update(chunk);
      crc = crc32(chunk, crc);
      if (keep) kept.push(chunk);
    }
  };
  const source = createReadStream(path, { start: dataStart, end: dataStart + entry.compressed - 1 });
  try {
    if (entry.method === 8) await pipeline(source, createInflateRaw(), consume);
    else await pipeline(source, consume);
  } catch {
    invalid();
  }
  if (size !== entry.size || crc !== entry.crc) invalid();
  return {
    sha1: sha1.digest('hex'), sha256: sha256.digest('hex'), head: head.toString('hex'), size,
    bytes: keep ? Buffer.concat(kept) : undefined,
  };
}

// MARK: XML property lists (CodeResources is always XML)

type Plist = string | boolean | number | Buffer | Plist[] | { [key: string]: Plist };
type Token =
  | { kind: 'open'; name: string }
  | { kind: 'close'; name: string }
  | { kind: 'empty'; name: string }
  | { kind: 'text'; text: string };

const DECODE: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-fA-F]+|#\d+|[a-z]+);/g, (match, entity: string) => {
    if (entity.startsWith('#x')) return String.fromCodePoint(parseInt(entity.slice(2), 16));
    if (entity.startsWith('#')) return String.fromCodePoint(parseInt(entity.slice(1), 10));
    return DECODE[entity] ?? invalid();
  });
}

function tokenize(xml: string): Token[] {
  const tokens: Token[] = [];
  const pattern = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!DOCTYPE[^>]*>|<(\/?)([A-Za-z]+)((?:\s[^>]*?)?)(\/?)>|([^<]+)/g;
  let position = 0;
  let match: RegExpExecArray | null;
  while (position < xml.length) {
    pattern.lastIndex = position;
    match = pattern.exec(xml);
    if (!match || match.index !== position) invalid();
    position = pattern.lastIndex;
    const [whole, slash = '', name = '', , selfClose = '', text] = match;
    if (whole.startsWith('<!--') || whole.startsWith('<?') || whole.startsWith('<!DOCTYPE')) continue;
    if (text !== undefined) { tokens.push({ kind: 'text', text: decodeEntities(text) }); continue; }
    if (slash) tokens.push({ kind: 'close', name });
    else if (selfClose.includes('/')) tokens.push({ kind: 'empty', name });
    else tokens.push({ kind: 'open', name });
  }
  return tokens;
}

export function parseXmlPlist(xml: string): Plist {
  const tokens = tokenize(xml);
  let index = 0;
  const skipText = () => {
    for (let token = tokens[index]; token?.kind === 'text' && /^\s*$/.test(token.text); token = tokens[index]) index++;
  };
  const readContent = (): string => {
    let text = '';
    for (let token = tokens[index]; token?.kind === 'text'; token = tokens[index]) { text += token.text; index++; }
    return text;
  };
  const expectClose = (name: string) => {
    const token = tokens[index++];
    if (!token || token.kind !== 'close' || token.name !== name) invalid();
  };
  const parseValue = (): Plist => {
    skipText();
    const token = tokens[index++];
    if (!token) invalid();
    if (token.kind === 'empty') {
      if (token.name === 'true') return true;
      if (token.name === 'false') return false;
      if (token.name === 'dict') return {};
      if (token.name === 'array') return [];
      invalid();
    }
    if (token.kind !== 'open') invalid();
    switch (token.name) {
      case 'string': { const v = readContent(); expectClose('string'); return v; }
      case 'integer': { const v = readContent().trim(); expectClose('integer'); return Number(v); }
      case 'real': { const v = readContent().trim(); expectClose('real'); return Number(v); }
      case 'date': { const v = readContent(); expectClose('date'); return v; }
      case 'data': {
        const v = readContent().replace(/\s+/g, '');
        expectClose('data');
        if (!/^[A-Za-z0-9+/]*={0,2}$/.test(v)) invalid();
        return Buffer.from(v, 'base64');
      }
      case 'array': {
        const items: Plist[] = [];
        for (skipText(); tokens[index]?.kind !== 'close'; skipText()) items.push(parseValue());
        expectClose('array');
        return items;
      }
      case 'dict': {
        const dict: { [key: string]: Plist } = {};
        for (skipText(); tokens[index]?.kind !== 'close'; skipText()) {
          const keyToken = tokens[index++];
          if (!keyToken || keyToken.kind !== 'open' || keyToken.name !== 'key') invalid();
          const key = readContent();
          expectClose('key');
          if (Object.prototype.hasOwnProperty.call(dict, key)) invalid();
          dict[key] = parseValue();
        }
        expectClose('dict');
        return dict;
      }
      default:
        invalid();
    }
  };
  skipText();
  if (tokens[index]?.kind !== 'open' || (tokens[index] as { name: string }).name !== 'plist') invalid();
  index++;
  const root = parseValue();
  skipText();
  expectClose('plist');
  skipText();
  if (index !== tokens.length) invalid();
  return root;
}

function asDict(value: Plist | undefined): { [key: string]: Plist } {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Buffer.isBuffer(value)) invalid();
  return value;
}

// MARK: Seal verification

type ArchiveFile = Digest & { entry: Entry };
const RESOURCES = /(^|\/)_CodeSignature\/CodeResources$/;

/**
 * Verifies that `path` is a well-formed IPA whose app bundle, and every nested bundle with its own
 * seal, matches its `_CodeSignature/CodeResources`. Throws `INVALID_OUTPUT` on any failure.
 */
export async function verifyIpaSeal(path: string, limits: SealLimits = DEFAULT_SEAL_LIMITS): Promise<void> {
  const handle = await open(path, 'r');
  try {
    const { size } = await handle.stat();
    const entries = await readEntries(handle, size, limits);

    let total = 0;
    const sealedContents = new Map<string, string>();
    const files = new Map<string, ArchiveFile>();
    for (const entry of entries) {
      if (entry.isDirectory) continue;
      total += entry.size;
      if (total > limits.maxTotalBytes) invalid();
      const keep = RESOURCES.test(entry.name);
      const digest = await digestEntry(path, handle, entry, limits, keep);
      if (keep && digest.bytes) sealedContents.set(entry.name, digest.bytes.toString('utf8'));
      files.set(entry.name, { sha1: digest.sha1, sha256: digest.sha256, head: digest.head, size: digest.size, entry });
    }

    // Exactly one app bundle directly under Payload/. Other top-level entries (iTunesMetadata.plist,
    // SC_Info, Symbols) are not installed code and are ignored.
    const apps = new Set<string>();
    for (const name of [...files.keys()]) {
      const match = /^Payload\/[^/]+\.app\//.exec(name);
      if (match) apps.add(match[0]);
    }
    if (apps.size !== 1) invalid();
    const appRoot = [...apps][0];
    if (appRoot === undefined) invalid();

    const verified = new Set<string>();
    const verifyBundle = (root: string, isApp: boolean): void => {
      if (verified.has(root)) return;
      verified.add(root);
      const resourcesName = `${root}_CodeSignature/CodeResources`;
      const resources = files.get(resourcesName);
      if (!resources) invalid();
      if (resources.size > limits.maxSealedFileBytes) invalid();
      const sealed = new Set<string>([resourcesName]);
      const xml = sealedContents.get(resourcesName);
      if (xml === undefined) invalid();
      const seal = asDict(parseXmlPlist(xml));
      const files2 = asDict(seal.files2);
      // Paths the seal deliberately leaves out (`omit = true` in rules2, e.g. locversion.plist in .lproj
      // folders). Apple's own tools skip these too, so their absence is not tampering.
      const omitted = Object.entries(seal.rules2 === undefined ? {} : asDict(seal.rules2))
        .filter(([, rule]) => asDict(rule).omit === true)
        .map(([pattern]) => {
          try { return new RegExp(`^${pattern.replace(/^\^/, '').replace(/\$$/, '')}$`); } catch { return invalid(); }
        });
      for (const [relative, value] of Object.entries(files2)) {
        safeArchivePath(relative);
        const record = asDict(value);
        const full = root + relative;
        const archived = files.get(full);
        if (!archived) {
          if (record.optional === true) continue;
          invalid();
        }
        const sha256 = record.hash2;
        if (!Buffer.isBuffer(sha256) || sha256.length !== 32) invalid();
        if (sha256.toString('hex') !== archived.sha256) invalid();
        if (record.hash !== undefined) {
          if (!Buffer.isBuffer(record.hash) || record.hash.length !== 20) invalid();
          if (record.hash.toString('hex') !== archived.sha1) invalid();
        }
        sealed.add(full);
      }

      const nested = new Set<string>();
      const roots: string[] = [];
      for (const name of files.keys()) {
        if (!name.startsWith(root) || name === resourcesName) continue;
        const rest = name.slice(root.length);
        const segments = rest.split('/');
        const bundleIndex = segments.slice(0, -1).findIndex(segment => NESTED_BUNDLE.test(segment));
        if (bundleIndex >= 0) {
          const nestedRoot = root + segments.slice(0, bundleIndex + 1).join('/') + '/';
          if (files.has(`${nestedRoot}_CodeSignature/CodeResources`)) {
            nested.add(nestedRoot);
            continue;
          }
        }
        if (sealed.has(name)) continue;
        // The one unsealed file a bundle may hold is its main executable at the bundle root; its
        // hash lives in the CodeDirectory, which is outside this check.
        if (segments.length === 1 && MACHO_MAGIC.has(files.get(name)!.head)) {
          roots.push(name);
          continue;
        }
        if (omitted.some(pattern => pattern.test(rest))) continue;
        invalid();
      }
      if (roots.length > 1) invalid();
      if (isApp && roots.length !== 1) invalid();
      for (const nestedRoot of nested) verifyBundle(nestedRoot, false);
    };
    verifyBundle(appRoot, true);
  } finally {
    await handle.close();
  }
}

