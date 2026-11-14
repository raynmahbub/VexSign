#!/usr/bin/env node
import { createHash, createPrivateKey, sign } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { link, lstat, mkdir, unlink, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const METHODS = new Set([
  'testFlight', 'appStore', 'adHoc', 'enterprise', 'mobileDeviceManagement',
  'personalTeam', 'directOTA', 'artifactDownload',
]);
const CLASSES = new Set([
  'development', 'adHoc', 'enterprise', 'appStore', 'personalTeam', 'unsigned', 'unknown',
]);
const CHANNELS = new Set(['stable', 'beta', 'alpha', 'development']);

export async function sha256File(filePath) {
  const details = await lstat(filePath);
  if (!details.isFile() || details.isSymbolicLink() || details.size < 1) {
    throw new Error('Artifact must be a non-empty regular file');
  }
  const digest = createHash('sha256');
  for await (const chunk of createReadStream(filePath, { highWaterMark: 1024 * 1024 })) {
    digest.update(chunk);
  }
  return digest.digest('hex');
}

export function validateManifestPayload(manifest) {
  const bundlePattern = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;
  const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)(\.(0|[1-9]\d*))?(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$/;
  const buildPattern = /^[0-9]+(\.[0-9]+)*$/;
  const fingerprintPattern = /^[a-fA-F0-9]{64}$/;
  if (manifest.schemaVersion !== 1 || !bundlePattern.test(manifest.applicationIdentifier)) {
    throw new Error('Unsupported schema or invalid application identifier');
  }
  if (!versionPattern.test(manifest.version) || !versionPattern.test(manifest.minimumOSVersion)) {
    throw new Error('Invalid semantic version or minimum OS version');
  }
  if (!buildPattern.test(manifest.buildNumber) || !CHANNELS.has(manifest.channel)) {
    throw new Error('Invalid build number or release channel');
  }
  for (const field of ['downloadURL', 'releaseNotesURL']) {
    if (manifest[field] == null && field === 'releaseNotesURL') continue;
    const url = new URL(manifest[field]);
    if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) {
      throw new Error(`Invalid HTTPS ${field}`);
    }
  }
  if (!fingerprintPattern.test(manifest.ipaSHA256)) throw new Error('Invalid IPA SHA-256');
  const { distributionMethod, signingClass, teamIdentifier, certificateSHA256 } = manifest.signing ?? {};
  if (!METHODS.has(distributionMethod) || !CLASSES.has(signingClass)) {
    throw new Error('Invalid distribution method or signing class');
  }
  const compatible = {
    testFlight: ['appStore'], appStore: ['appStore'], adHoc: ['adHoc'],
    enterprise: ['enterprise'], personalTeam: ['personalTeam'],
    directOTA: ['adHoc', 'enterprise'],
    mobileDeviceManagement: ['appStore', 'adHoc', 'enterprise'],
    artifactDownload: ['unsigned'],
  };
  if (!compatible[distributionMethod].includes(signingClass)) {
    throw new Error('Distribution method and signing class are incompatible');
  }
  if (teamIdentifier != null && !/^[A-Z0-9]{10}$/.test(teamIdentifier)) {
    throw new Error('Invalid signing team identifier');
  }
  if (certificateSHA256 != null && !fingerprintPattern.test(certificateSHA256)) {
    throw new Error('Invalid signing certificate fingerprint');
  }
  const createdAt = Date.parse(manifest.createdAt);
  const expiresAt = Date.parse(manifest.expiresAt);
  const now = Date.now();
  if (!Number.isFinite(createdAt) || !Number.isFinite(expiresAt)
      || createdAt > now + 300_000 || expiresAt <= now
      || expiresAt - createdAt > 7_776_000_000) {
    throw new Error('Invalid release metadata validity interval');
  }
  return manifest;
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

export function createSignedEnvelope(manifest, privateKeyPEM, keyID) {
  validateManifestPayload(manifest);
  if (manifest.signing.distributionMethod !== 'artifactDownload'
      || manifest.signing.signingClass !== 'unsigned') {
    throw new Error('Signer currently authenticates download-only unsigned artifacts; installation eligibility is not established');
  }
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(keyID)) throw new Error('Invalid signing key ID');
  const privateKey = createPrivateKey(privateKeyPEM);
  if (privateKey.asymmetricKeyType !== 'ed25519') throw new Error('Release key must be Ed25519');
  const payload = Buffer.from(canonicalJSON(manifest), 'utf8');
  const signature = sign(null, payload, privateKey);
  return {
    schemaVersion: 1,
    algorithm: 'Ed25519',
    keyID,
    payloadBase64: payload.toString('base64'),
    signatureBase64: signature.toString('base64'),
  };
}

export async function createManifest({ artifactPath, outputPath, privateKeyPEM, keyID, metadata }) {
  const digest = await sha256File(artifactPath);
  const now = new Date();
  const toISOSeconds = (date) => date.toISOString().replace(/\.\d{3}Z$/, 'Z');
  const manifest = {
    schemaVersion: 1,
    applicationIdentifier: metadata.applicationIdentifier,
    version: metadata.version,
    buildNumber: metadata.buildNumber,
    channel: metadata.channel,
    minimumOSVersion: metadata.minimumOSVersion,
    downloadURL: metadata.downloadURL,
    ipaSHA256: digest,
    releaseNotesURL: metadata.releaseNotesURL ?? null,
    createdAt: toISOSeconds(now),
    expiresAt: toISOSeconds(new Date(now.getTime() + metadata.expirySeconds * 1000)),
    signing: {
      distributionMethod: metadata.distributionMethod,
      signingClass: metadata.signingClass,
      teamIdentifier: metadata.teamIdentifier ?? null,
      certificateSHA256: metadata.certificateSHA256 ?? null,
    },
  };
  const envelope = createSignedEnvelope(manifest, privateKeyPEM, keyID);
  const destination = resolve(outputPath);
  await mkdir(dirname(destination), { recursive: true });
  const temporary = `${destination}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(envelope, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  try {
    // Hard-link publication is atomic and fails if a release manifest already exists.
    await link(temporary, destination);
  } catch (error) {
    await unlink(temporary).catch(() => {});
    throw error;
  }
  await unlink(temporary);
  return { manifest, outputPath: destination };
}

function parseArguments(args) {
  const values = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith('--') || value == null || value.startsWith('--')) {
      throw new Error('Arguments must be provided as --name value pairs');
    }
    values[key.slice(2)] = value;
  }
  return values;
}

async function main() {
  const args = parseArguments(process.argv.slice(2));
  const privateKeyPEM = process.env.VEXSIGN_RELEASE_MANIFEST_PRIVATE_KEY;
  const keyID = process.env.VEXSIGN_RELEASE_MANIFEST_KEY_ID;
  if (!privateKeyPEM || !keyID) throw new Error('Protected manifest-signing key configuration is missing');
  const required = [
    'artifact', 'output', 'application-identifier', 'version', 'build-number', 'channel',
    'minimum-os', 'download-url', 'expiry-seconds', 'distribution-method', 'signing-class',
  ];
  for (const key of required) if (!args[key]) throw new Error(`Missing required argument --${key}`);
  const expirySeconds = Number(args['expiry-seconds']);
  if (!Number.isInteger(expirySeconds) || expirySeconds < 60 || expirySeconds > 7_776_000) {
    throw new Error('Expiry must be between 60 seconds and 90 days');
  }
  await createManifest({
    artifactPath: args.artifact,
    outputPath: args.output,
    privateKeyPEM,
    keyID,
    metadata: {
      applicationIdentifier: args['application-identifier'],
      version: args.version,
      buildNumber: args['build-number'],
      channel: args.channel,
      minimumOSVersion: args['minimum-os'],
      downloadURL: args['download-url'],
      releaseNotesURL: args['release-notes-url'],
      expirySeconds,
      distributionMethod: args['distribution-method'],
      signingClass: args['signing-class'],
      teamIdentifier: args['team-id'] ?? null,
      certificateSHA256: args['certificate-sha256'] ?? null,
    },
  });
  process.stdout.write('Signed release manifest written; private key material was not logged.\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
