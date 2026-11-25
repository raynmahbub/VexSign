#!/usr/bin/env python3
"""Run VexSignTests on a simulator or a connected device with xcodebuild.

This is an exec wrapper, not a simulator: it refuses to pretend a device run happened
when Xcode or a destination is unavailable. The resulting .xcresult is left on disk for
the per-feature report in `Tools/Audit/feature-acceptance.py` to reference.
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--destination",
        required=True,
        help='xcodebuild destination, e.g. "platform=iOS Simulator,name=iPhone 16" '
             'or "id=<UDID>" for a connected device',
    )
    parser.add_argument("--workspace", default="VexSign.xcworkspace")
    parser.add_argument("--scheme", default="VexSignTests")
    parser.add_argument("--configuration", default="Debug")
    parser.add_argument("--result-bundle", default=".artifacts/VexSignTests.xcresult")
    parser.add_argument("--derived-data", default=".artifacts/DerivedData")
    parser.add_argument(
        "--only-testing",
        action="append",
        default=[],
        help="Optional XCTest identifier; repeat for more than one",
    )
    args = parser.parse_args()

    xcodebuild = shutil.which("xcodebuild")
    if not xcodebuild:
        parser.exit(
            2,
            "error: xcodebuild was not found. Install Xcode and run this on macOS; "
            "portable Python gates cannot execute iOS tests.\n",
        )

    workspace = Path(args.workspace)
    if not (ROOT / workspace).exists():
        parser.exit(1, f"error: workspace not found: {workspace}\n")
    result_bundle = Path(args.result_bundle)
    if result_bundle.exists():
        parser.exit(1, f"error: {result_bundle} already exists; move it before overwriting evidence\n")

    command = [
        xcodebuild,
        "-skipPackagePluginValidation",
        "-workspace", str(workspace),
        "-scheme", args.scheme,
        "-configuration", args.configuration,
        "-destination", args.destination,
        "-derivedDataPath", str(Path(args.derived_data).resolve()),
        "-resultBundlePath", str(result_bundle.resolve()),
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGNING_REQUIRED=YES",
        "CODE_SIGN_IDENTITY=-",
        "AD_HOC_CODE_SIGNING_ALLOWED=YES",
        "COMPILER_INDEX_STORE_ENABLE=NO",
        "ONLY_ACTIVE_ARCH=YES",
    ]
    for identifier in args.only_testing:
        command.append(f"-only-testing:{args.scheme}/{identifier}")

    command.append("test")
    print("Running:", " ".join(command), flush=True)
    completed = subprocess.run(command, cwd=ROOT, check=False)
    if completed.returncode == 0:
        print(f"Result bundle: {result_bundle}")
    else:
        print(f"xcodebuild failed with status {completed.returncode}; no pass is claimed.", file=sys.stderr)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
