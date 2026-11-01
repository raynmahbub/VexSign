#!/usr/bin/env python3
"""Pick an available iPhone simulator for `xcodebuild test`.

Why a script instead of a hard-coded destination: the simulator names shipped
with each Xcode change (iPhone 15 -> 16 -> 17 ...), so a workflow pinned to one
name breaks the day the runner image updates. This asks CoreSimulator what is
actually installed and picks deterministically.

Selection order:
  1. iOS runtimes only (never watchOS/tvOS/visionOS devices).
  2. iPhones only.
  3. Newest runtime first, then newest iPhone generation, then alphabetical.
  4. Prefer an already-booted device when it is otherwise equally good (faster
     test start).

Usage:
    python3 select_simulator.py                 # "iPhone 16 (26.0) <UDID>"
    python3 select_simulator.py --print-id      # just the UDID
    python3 select_simulator.py --json-file f   # parse a saved simctl payload

Exit status is non-zero (with a message on stderr) when no iPhone simulator is
available, which is the only case where the caller should give up.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

RUNTIME_PREFIX = "com.apple.CoreSimulator.SimRuntime.iOS-"


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load_devices(json_file: str | None) -> dict:
    if json_file:
        try:
            with open(json_file, encoding="utf-8") as handle:
                return json.load(handle)
        except OSError as error:
            fail(f"Could not read {json_file}: {error}")
        except json.JSONDecodeError as error:
            fail(f"{json_file} is not valid JSON: {error}")

    try:
        completed = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "--json"],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        fail(
            "xcrun was not found. Install Xcode (and run "
            "`sudo xcode-select -s /Applications/Xcode.app`) to run the tests."
        )

    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        fail(f"`xcrun simctl list devices available` failed:\n{detail}")

    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        fail(f"Could not parse simctl output: {error}")


def runtime_version(runtime_key: str) -> tuple[int, ...]:
    """com.apple.CoreSimulator.SimRuntime.iOS-26-0 -> (26, 0)"""
    suffix = runtime_key[len(RUNTIME_PREFIX):]
    parts = []
    for piece in suffix.split("-"):
        if not piece.isdigit():
            break
        parts.append(int(piece))
    return tuple(parts) or (0,)


def iphone_generation(name: str) -> tuple[int, ...]:
    """'iPhone 16 Pro' -> (16, 1); 'iPhone SE (3rd generation)' -> (0, 0)."""
    match = re.search(r"iPhone\s+(\d+)", name)
    if not match:
        return (0,)
    numbers = [int(match.group(1))]
    if re.search(r"\bPro\b", name):
        numbers.append(2)
    elif re.search(r"\bPlus\b", name):
        numbers.append(1)
    else:
        numbers.append(0)
    return tuple(numbers)


def candidates(payload: dict) -> list[tuple[tuple, dict, str, str]]:
    found = []
    for runtime_key, devices in (payload.get("devices") or {}).items():
        if not runtime_key.startswith(RUNTIME_PREFIX):
            continue
        version = runtime_version(runtime_key)
        for device in devices or []:
            name = device.get("name") or ""
            udid = device.get("udid") or ""
            if not udid or not name.startswith("iPhone"):
                continue
            if device.get("isAvailable") is False:
                continue
            # Sort key: runtime, then model generation, then booted, then name.
            booted = 1 if (device.get("state") == "Booted") else 0
            key = (version, iphone_generation(name), booted, name)
            found.append((key, device, runtime_key, name))
    return found


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--print-id", action="store_true", help="print only the simulator UDID")
    parser.add_argument("--json-file", default=None, help="parse a saved simctl JSON payload instead of running xcrun")
    args = parser.parse_args()

    found = candidates(load_devices(args.json_file))
    if not found:
        fail(
            "No available iPhone simulator found. Install an iOS runtime in "
            "Xcode → Settings → Components, or run `xcrun simctl list devices available` to inspect."
        )

    key, device, runtime_key, name = max(found, key=lambda item: item[0])
    version = ".".join(str(part) for part in key[0])

    if args.print_id:
        print(device["udid"])
        return

    print(f"{name} ({version}) {device['udid']}")


if __name__ == "__main__":
    main()
