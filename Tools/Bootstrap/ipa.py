from __future__ import annotations

import plistlib
import re
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


class IPAValidationError(RuntimeError):
    pass


BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+$")


@dataclass(frozen=True)
class IPAInspection:
    path: Path
    bundle_identifier: str
    version: str
    build: str
    app_path: str


def inspect_ipa(path: Path, *, expected_bundle_id: str | None = None, max_entries: int = 5000) -> IPAInspection:
    if not path.exists() or not path.is_file() or path.is_symlink():
        raise IPAValidationError("IPA must be an existing regular file")
    with zipfile.ZipFile(path) as zf:
        infos = zf.infolist()
        if len(infos) > max_entries:
            raise IPAValidationError("IPA has too many entries")
        app_dirs = []
        total_uncompressed = 0
        for info in infos:
            name = info.filename
            if not name:
                raise IPAValidationError("IPA contains empty entry name")
            if name.startswith("/") or name.startswith("\\") or ".." in name.replace("\\", "/").split("/"):
                raise IPAValidationError(f"Unsafe IPA path: {name}")
            mode = (info.external_attr >> 16) & 0o170000
            if mode == 0o120000:
                raise IPAValidationError(f"IPA symlink not allowed: {name}")
            total_uncompressed += info.file_size
            if info.file_size > 512 * 1024 * 1024:
                raise IPAValidationError(f"IPA entry too large: {name}")
            if re.match(r"^Payload/[^/]+\.app/$", name):
                app_dirs.append(name)
        if total_uncompressed > 2 * 1024 * 1024 * 1024:
            raise IPAValidationError("IPA uncompressed size too large")
        if len(app_dirs) != 1:
            raise IPAValidationError("IPA must contain exactly one top-level .app bundle in Payload/")
        app_path = app_dirs[0]
        info_path = app_path + "Info.plist"
        try:
            with zf.open(info_path) as f:
                info = plistlib.load(f)
        except KeyError as e:
            raise IPAValidationError("IPA missing Info.plist") from e
        except Exception as e:
            raise IPAValidationError(f"Invalid Info.plist: {e}") from e
        bundle_id = info.get("CFBundleIdentifier")
        version = info.get("CFBundleShortVersionString")
        build = info.get("CFBundleVersion")
        if not isinstance(bundle_id, str) or not BUNDLE_ID_RE.match(bundle_id):
            raise IPAValidationError("Invalid CFBundleIdentifier")
        if not isinstance(version, str) or not version.strip():
            raise IPAValidationError("Invalid CFBundleShortVersionString")
        if not isinstance(build, str) or not build.strip():
            raise IPAValidationError("Invalid CFBundleVersion")
        if expected_bundle_id and bundle_id != expected_bundle_id:
            raise IPAValidationError(f"Unexpected bundle identifier: {bundle_id}")
        _validate_nested_bundles(zf, app_path)
        return IPAInspection(path=path, bundle_identifier=bundle_id, version=version.strip(), build=build.strip(), app_path=app_path)


def _validate_nested_bundles(zf: zipfile.ZipFile, app_path: str) -> None:
    nested_patterns = (
        re.compile(rf"^{re.escape(app_path)}PlugIns/[^/]+\.appex/Info\.plist$"),
        re.compile(rf"^{re.escape(app_path)}Frameworks/[^/]+\.framework/Info\.plist$"),
        re.compile(rf"^{re.escape(app_path)}Extensions/[^/]+\.appex/Info\.plist$"),
    )
    for info in zf.infolist():
        name = info.filename
        if not any(p.match(name) for p in nested_patterns):
            continue
        try:
            with zf.open(name) as f:
                plist = plistlib.load(f)
        except Exception as e:
            raise IPAValidationError(f"Invalid nested bundle Info.plist: {name}") from e
        bid = plist.get("CFBundleIdentifier")
        if not isinstance(bid, str) or not BUNDLE_ID_RE.match(bid):
            raise IPAValidationError(f"Invalid nested bundle identifier: {name}")


def verify_ipa_checksum(path: Path, expected_sha256: str) -> None:
    from .integrity import verify_sha256

    verify_sha256(path, expected_sha256)
