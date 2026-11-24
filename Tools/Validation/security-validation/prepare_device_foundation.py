#!/usr/bin/env python3
"""Stage exact production parser/storage/executor sources for credential-free macOS tests.

Does not resolve SwiftPM dependencies, load IDevice, contact Apple, or run tests.
Generated files live under .build/device-foundation and are never release inputs.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / ".build/device-foundation"
VENDOR = "Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/Heartbeat"
TESTS = "Tests/UnitTests/Devices"
PRODUCTION = {
    **{name: f"{VENDOR}/{name}" for name in (
        "PairingRecordDocument.swift", "PairingPlistEnvelope.swift", "PairingFileStorage.swift",
        "DeviceTransportPolicy.swift", "DeviceOperationExecutor.swift",
    )},
    **{name: f"{VENDOR.rsplit('/', 1)[0]}/InstallationProxy/{name}" for name in (
        "DeviceApplicationInventory.swift", "DeviceInstallationSubmission.swift",
    )},
}
FIXTURES = (
    "PairingRecordTestFixtures.swift", "PairingRecordFoundationTests.swift",
    "PairingFileStorageTests.swift", "DeviceOperationExecutorTests.swift", "DeviceApplicationInventoryTests.swift",
)
MANIFEST = '''// swift-tools-version: 5.9
// Test packaging only. Production source bytes are copied without rewriting.
import PackageDescription
let package = Package(
    name: "VexSignDeviceFoundationTests",
    platforms: [.macOS(.v13)],
    products: [.library(name: "DeviceFoundation", targets: ["DeviceFoundation"])],
    targets: [
        .target(name: "DeviceFoundation"),
        .testTarget(name: "DeviceFoundationTests", dependencies: ["DeviceFoundation"])
    ]
)
'''


def prepare(output: Path = OUTPUT) -> dict[str, str]:
    """Own only explicitly listed generated files. Refuse links/unexpected sources.

    `output` is injectable for temporary-directory tests, not a command-line path
    capable of erasing an arbitrary checkout. No recursive deletion is performed.
    """
    output = Path(output)
    if output.name != "device-foundation" or output.is_symlink():
        raise ValueError("Expected a non-symlink device-foundation output directory")
    mapping = {
        **{relative: f"Sources/DeviceFoundation/{name}" for name, relative in PRODUCTION.items()},
        **{f"{TESTS}/{name}": f"Tests/DeviceFoundationTests/{name}" for name in FIXTURES},
        "Packages/Vendor/IDeviceKitten/LICENSE": "UPSTREAM-LICENSE.txt",
    }
    # Validate every source before creating/changing output. A tracked symlink
    # must not turn a credential-free test graph into a read outside the checkout.
    inputs = {}
    for relative in mapping:
        source = ROOT / relative
        if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(ROOT.resolve()):
            raise ValueError("Production/test inputs must be regular files inside the checkout")
        if any(parent.is_symlink() for parent in source.parents if parent.is_relative_to(ROOT)):
            raise ValueError("Production/test source ancestors must not be symlinks")
        inputs[relative] = source.read_bytes()
    expected = set(mapping.values()) | {"Package.swift", "source-hashes.json"}
    for relative in expected:
        target = output / relative
        if target.is_symlink() or any(parent.is_symlink() for parent in target.parents):
            raise ValueError("Generated output must not contain symlinks")
    for folder in (output / "Sources", output / "Tests"):
        if folder.exists():
            if folder.is_symlink():
                raise ValueError("Generated source directory is a symlink")
            for file in folder.rglob("*"):
                if file.is_symlink() or (file.is_file() and file.relative_to(output).as_posix() not in expected):
                    raise ValueError("Unexpected generated source; use a clean device-foundation directory")
    hashes = {}
    for source, destination in mapping.items():
        data = inputs[source]
        target = output / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        hashes[source] = hashlib.sha256(data).hexdigest()
    (output / "Package.swift").write_text(MANIFEST, encoding="utf-8")
    (output / "source-hashes.json").write_text(json.dumps({
        "schema": 1,
        "scope": "synthetic host tests; not native ABI, iOS Data Protection or physical acceptance",
        "sourceSHA256": hashes,
    }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return hashes


if __name__ == "__main__":
    hashes = prepare()
    print(f"Staged {len(PRODUCTION)} exact production files and {len(FIXTURES)} test files in .build/device-foundation")
    print("On macOS: swift test --package-path .build/device-foundation")
    print("No Swift compilation or device acceptance is implied by preparation.")
