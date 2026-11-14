import { createCipheriv, createDecipheriv, createHmac, hkdfSync, randomBytes, timingSafeEqual } from 'node:crypto';

export function seal(value: string, masterKey: Buffer, context: string): string {
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', masterKey, nonce);
  cipher.setAAD(Buffer.from(context));
  const ciphertext = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return Buffer.concat([nonce, cipher.getAuthTag(), ciphertext]).toString('base64');
}
export function unseal(value: string, masterKey: Buffer, context: string): string {
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length < 28) throw new Error('Invalid sealed data');
  const decipher = createDecipheriv('aes-256-gcm', masterKey, bytes.subarray(0, 12));
  decipher.setAuthTag(bytes.subarray(12, 28)); decipher.setAAD(Buffer.from(context));
  return Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString('utf8');
}
function capabilityKey(masterKey: Buffer): Buffer {
  return Buffer.from(hkdfSync('sha256', masterKey, '', 'vexsign.ota.capability.v1', 32));
}
export function capability(id: string, expires: number, key: Buffer): string {
  const mac = createHmac('sha256', capabilityKey(key)).update(`${id}:${expires}`).digest('base64url');
  return `${expires}.${mac}`;
}
export function verifyCapability(id: string, value: string, key: Buffer, now = Date.now()): boolean {
  const parts = value.split('.');
  if (parts.length !== 2 || !/^\d{10}$/.test(parts[0] ?? '')) return false;
  const expires = Number(parts[0]);
  if (expires * 1000 <= now || expires * 1000 > now + 7 * 86400_000) return false;
  const expected = Buffer.from(capability(id, expires, key)); const actual = Buffer.from(value);
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}
export function escapeMarkup(value: string): string {
  return value.replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]!);
}
export function permittedWebhook(value: string | undefined, allowlist: string): boolean {
  if (!value) return true;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password && !url.hash
      && allowlist.split(',').map(v => v.trim()).includes(url.href);
  } catch { return false; }
}
