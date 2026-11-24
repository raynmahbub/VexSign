#!/usr/bin/env bash
# macOS + Xcode. Produce an unsigned, importable fixture, not a signed install.
set -euo pipefail
: "${1:?Usage: build.sh /path/to/new.ipa com.yourteam.fixture}"
: "${2:?Supply your own explicit test bundle identifier}"
[[ ! -e "$1" && "$2" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo 'Use a new output file and a valid bundle ID.' >&2; exit 1; }
src=$(cd "$(dirname "$0")" && pwd)
out=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
app="$tmp/Payload/RenewalFixture.app"; mkdir -p "$app"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos swiftc -parse-as-library -O -target arm64-apple-ios17.0 -sdk "$sdk" "$src/Fixture.swift" "$src/../../../VexSign/App/iOS/Infrastructure/Devices/Installation/FixtureSlotPacket.swift" -o "$app/RenewalFixture"
python3 - "$app/Info.plist" "$2" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier=sys.argv[2], CFBundleName='RenewalFixture', CFBundleDisplayName='Renewal Fixture',
                      CFBundleExecutable='RenewalFixture', CFBundlePackageType='APPL', CFBundleVersion='1',
                      CFBundleShortVersionString='1.0', CFBundleInfoDictionaryVersion='6.0', MinimumOSVersion='17.0',
                      CFBundleSupportedPlatforms=['iPhoneOS'], UIDeviceFamily=[1, 2], LSRequiresIPhoneOS=True,
                      VexSignMarkerFixture=True, UILaunchScreen={}), f)
PY
(cd "$tmp" && zip -qr fixture.ipa Payload)
# noclobber even if the requested destination appeared during compilation.
(set -C; cat "$tmp/fixture.ipa" > "$out")
