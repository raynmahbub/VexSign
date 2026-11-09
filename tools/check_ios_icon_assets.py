#!/usr/bin/env python3
"""Check VexSign's iOS app-icon catalog stays square, opaque and appearance-complete."""
from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "VexSign/Resources/Assets.xcassets/AppIcon.appiconset"
EXPECTED_APPEARANCES = {None, "dark", "tinted"}


def png_info(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"{path.relative_to(ROOT)} is not a valid PNG")
    width, height = struct.unpack(">II", data[16:24])
    color_type = data[25]
    return width, height, color_type


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    catalog = json.loads((ICONSET / "Contents.json").read_text())
    images = catalog.get("images", [])
    appearances: dict[str | None, Path] = {}

    for entry in images:
        appearance = None
        for item in entry.get("appearances", []):
            if item.get("appearance") == "luminosity":
                appearance = item.get("value")
        if appearance in appearances:
            raise ValueError(f"duplicate iOS icon appearance: {appearance}")
        if entry.get("idiom") != "universal" or entry.get("platform") != "ios":
            raise ValueError("app icons must be universal iOS assets")
        if entry.get("size") != "1024x1024":
            raise ValueError("app icon catalog entries must declare 1024x1024")

        path = ICONSET / entry["filename"]
        if not path.is_file():
            raise ValueError(f"missing app icon image: {path.relative_to(ROOT)}")
        width, height, color_type = png_info(path)
        if (width, height) != (1024, 1024):
            raise ValueError(f"{path.name} is {width}x{height}, expected 1024x1024")
        if color_type != 2:
            raise ValueError(f"{path.name} must be opaque RGB (no pre-rounded alpha mask)")
        appearances[appearance] = path

    if set(appearances) != EXPECTED_APPEARANCES:
        raise ValueError(f"expected standard/dark/tinted icon variants, got {set(appearances)}")

    standard = digest(appearances[None])
    for relative in (
        "icon.png",
        "VexSign/Resources/Assets.xcassets/AppLogo.imageset/AppLogo.png",
        "VexSign/Resources/Assets.xcassets/Glyph.imageset/vexsign.png",
    ):
        path = ROOT / relative
        if digest(path) != standard:
            raise ValueError(f"brand asset drift: {relative} differs from the standard iOS icon")

    if digest(appearances["dark"]) == standard or digest(appearances["tinted"]) == standard:
        raise ValueError("dark and tinted appearances must retain their own treatments")

    print("iOS icon catalog: 1024px opaque standard/dark/tinted assets and synchronized VexSign marks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
