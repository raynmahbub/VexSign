#!/usr/bin/env bash
# Explicit, local-only device action. Never run on an unattended hosted runner.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Real-device checks require macOS, Xcode and a paired, trusted iPhone/iPad.' >&2
  exit 1
fi
: "${DEVICE_ID:?Set DEVICE_ID to an explicitly selected paired device identifier}"
: "${SIGNED_APP:?Set SIGNED_APP to a signed VexSign .app directory}"
[[ -d "$SIGNED_APP" && "$SIGNED_APP" == *.app ]] || { echo 'SIGNED_APP must be a .app directory' >&2; exit 1; }
[[ "${CONFIRM_DEVICE_INSTALL:-}" == YES ]] || { echo 'Set CONFIRM_DEVICE_INSTALL=YES to authorize installation/replacement on this device.' >&2; exit 1; }
xcrun --find devicectl >/dev/null
codesign --verify --deep --strict "$SIGNED_APP"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SIGNED_APP/Info.plist")
[[ -n "$bundle_id" ]] || exit 1
# Installation validates the provisioning/signing on the actual device. Neither
# this nor process launch proves VexSign's own OTA installation pipeline works.
xcrun devicectl device install app --device "$DEVICE_ID" "$SIGNED_APP"
xcrun devicectl device process launch --device "$DEVICE_ID" "$bundle_id"
echo 'App installed and launch requested. Complete docs/DEVICE_TESTING.md before recording acceptance.'
