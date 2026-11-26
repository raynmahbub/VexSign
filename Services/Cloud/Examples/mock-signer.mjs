#!/usr/bin/env node
// Protocol fixture only: never signs or claims a certificate is valid.
let text = '';
for await (const chunk of process.stdin) {
  text += chunk;
  if (text.length > 64 * 1024) process.exit(1);
}
try {
  const input = JSON.parse(text);
  if (input.protocolVersion !== 1 || input.kind !== 'check-cert') process.exit(1);
  console.log(JSON.stringify({ kind: 'check-cert', certificate: {
    status: 'unknown', checkedAt: new Date().toISOString(), teamID: '', teamName: '',
    expiresAt: new Date(0).toISOString(), detail: 'Mock protocol fixture; no certificate verification performed.',
  } }));
} catch { process.exit(1); }
