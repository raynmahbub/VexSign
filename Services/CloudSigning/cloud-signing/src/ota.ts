import type { ArtifactMetadata } from './contracts.js';
import { escapeMarkup as e } from './security.js';
export function installLink(manifest: string): string {
  return `itms-services://?${new URLSearchParams({ action: 'download-manifest', url: manifest })}`;
}
export function manifest(metadata: ArtifactMetadata, download: string): string {
  if (new URL(download).protocol !== 'https:') throw new Error('HTTPS required');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict><key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>${e(download)}</string></dict></array><key>metadata</key><dict><key>bundle-identifier</key><string>${e(metadata.bundleIdentifier)}</string><key>bundle-version</key><string>${e(metadata.version)}</string><key>kind</key><string>software</string><key>title</key><string>${e(metadata.name)}</string></dict></dict></array></dict></plist>`;
}
export function installPage(app: ArtifactMetadata, link: string, qrDataURL: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>${e(app.name)} — VexSign</title><link rel="stylesheet" href="/assets/install.css"><script src="/assets/install.js" defer></script></head><body><main>
${app.iconURL ? `<img src="${e(app.iconURL)}" width="96" height="96" alt="App icon" referrerpolicy="no-referrer">` : ''}
<h1>${e(app.name)}</h1><p>Version ${e(app.version)}</p><p>Requires a valid signature and a device permitted by the provisioning profile.</p>
<p><a href="${e(link)}">Install App</a></p><label>Install link (select to copy)<input id="install-link" readonly size="60" value="${e(link)}" aria-label="Install link"></label><button id="copy-link" type="button">Copy Link</button>
<p><img src="${e(qrDataURL)}" width="256" height="256" alt="Install QR code"></p>
<h2>What’s New</h2><pre>${e(app.changelog)}</pre>
${app.screenshotURLs.map(url => `<img src="${e(url)}" width="240" alt="App screenshot" referrerpolicy="no-referrer" loading="lazy">`).join('')}
</main></body></html>`;
}
