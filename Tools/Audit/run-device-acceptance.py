#!/usr/bin/env python3
"""Install, launch and test a development-signed VexSign build on a real iPhone.

This script only runs on a macOS self-hosted runner with a connected device. It refuses
an ad-hoc CI IPA: that artifact proves compilation, not installability. Device identity
is supplied by the runner (`VEXSIGN_DEVICE_UDID` or --device) and must be explicit.

After install/launch it can run the native test bundle on the device and verify the
per-feature report. It cannot tap through the app by itself; those observations must
come from a UI test target or a named tester, and the report enforces that.
"""

import argparse
import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = "com.vexsign.app"


def run(command, log):
    print("Running:", " ".join(command), flush=True)
    result = subprocess.run(command, cwd=ROOT, check=False)
    log.write(" ".join(command) + f"\nexit={result.returncode}\n\n")
    log.flush()
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True, help="Development-signed IPA built for this device")
    parser.add_argument("--device", default=os.environ.get("VEXSIGN_DEVICE_UDID", ""),
                        help="Device UDID; defaults to VEXSIGN_DEVICE_UDID")
    parser.add_argument("--report", type=Path, help="feature-acceptance.py report to verify")
    parser.add_argument("--commit", help="Commit bound to the device report")
    parser.add_argument("--log", type=Path, default=Path(".artifacts/device-acceptance.log"))
    parser.add_argument("--run-tests", action="store_true", help="Run VexSignTests on the device destination")
    args = parser.parse_args()

    xcrun = shutil.which("xcrun")
    if not xcrun:
        parser.exit(2, "error: xcrun not found; physical-device tests need macOS/Xcode\n")
    if not args.device.strip():
        parser.exit(2, "error: no device UDID; pass --device or set VEXSIGN_DEVICE_UDID\n")
    if not args.ipa.is_file():
        parser.exit(1, f"error: IPA not found: {args.ipa}\n")
    if not os.environ.get("VEXSIGN_DEVICE_SIGNING_IDENTITY", "").strip():
        parser.exit(2, "error: set VEXSIGN_DEVICE_SIGNING_IDENTITY to the development certificate used for this IPA\n")

    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("a", encoding="utf-8") as log:
        log.write(f"device={args.device} ipa={args.ipa}\n\n")
        status = run([xcrun, "devicectl", "device", "install", "app",
                      "--device", args.device, str(args.ipa.resolve())], log)
        if status != 0:
            parser.exit(status, "error: device install failed; no launch is claimed\n")
        status = run([xcrun, "devicectl", "device", "process", "launch",
                      "--device", args.device, "--bundle-id", BUNDLE_ID], log)
        if status != 0:
            parser.exit(status, "error: device launch failed; no feature pass is claimed\n")

        if args.run_tests:
            status = run([
                xcrun, "xcodebuild",
                "-skipPackagePluginValidation",
                "-workspace", "VexSign.xcworkspace",
                "-scheme", "VexSignTests",
                "-configuration", "Debug",
                "-destination", f"id={args.device}",
                "-derivedDataPath", str((ROOT / ".artifacts/DeviceDerivedData").resolve()),
                "-resultBundlePath", str((ROOT / ".artifacts/VexSignDevice.xcresult").resolve()),
                "CODE_SIGNING_ALLOWED=YES",
                "CODE_SIGNING_REQUIRED=YES",
                "CODE_SIGN_IDENTITY=" + os.environ["VEXSIGN_DEVICE_SIGNING_IDENTITY"],
                "test",
            ], log)
            if status != 0:
                parser.exit(status, "error: native device tests failed\n")

    if args.report:
        import importlib.util
        spec = importlib.util.spec_from_file_location("vexsign_feature_acceptance", ROOT / "Tools/Audit/feature-acceptance.py")
        feature = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(feature)
        import json
        try:
            report = json.loads(args.report.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            parser.exit(1, f"error: {error}\n")
        errors = feature.check_report(report, args.ipa, args.commit)
        if errors:
            for error in errors:
                print(f"FAIL {error}")
            raise SystemExit(1)

    print(f"Device install and launch completed; log: {args.log}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
