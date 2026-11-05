#!/usr/bin/env bash
#
# Validate a fresh VexSign checkout and resolve its Swift packages.
# Safe to re-run; does not build the app or open Xcode.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

fail() {
    printf '\nerror: %s\n\n' "$*" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$*"
}

step "Platform"
if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "VexSign builds with Xcode on macOS. On Linux, run: make verify"
fi
printf 'macOS %s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)"

step "Xcode"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild was not found. Install Xcode and run: sudo xcode-select --switch /Applications/Xcode.app"
xcodebuild -version
printf 'Developer directory: %s\n' "$(xcode-select -p)"

step "Vendored packages"
for package in Vendor/Zsign Vendor/IDeviceKitten; do
    [[ -f "${package}/Package.swift" ]] || fail "${package}/Package.swift is missing. Restore the vendored sources from Vendor/README.md."
    printf 'found %s\n' "${package}"
done

if [[ -e .gitmodules ]]; then
    fail ".gitmodules is present, but VexSign no longer uses Git submodules. Remove it and use Vendor/ instead."
fi

step "Swift manifests"
if command -v swift >/dev/null 2>&1; then
    for package in Vendor/Zsign Vendor/IDeviceKitten; do
        swift package --package-path "${package}" dump-package >/dev/null \
            || fail "${package}/Package.swift could not be parsed"
        printf 'valid %s\n' "${package}"
    done
else
    printf 'swift was not found; skipping manifest validation (Xcode will resolve them).\n'
fi

step "Resolve Swift packages"
xcodebuild \
    -workspace VexSign.xcworkspace \
    -scheme VexSign \
    -resolvePackageDependencies \
    -skipPackagePluginValidation \
    -skipMacroValidation

step "Ready"
cat <<'TXT'
Open the workspace, choose the VexSign scheme and select your development team:

  open VexSign.xcworkspace

Useful next commands:
  make verify     fast repository and policy checks
  make            unsigned IPA in packages/
  make test       simulator tests

Full guide: docs/BUILD.md
TXT
