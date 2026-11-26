from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping


class IntegrityError(RuntimeError):
    pass


@dataclass(frozen=True)
class Artifact:
    name: str
    url: str
    sha256: str
    size: int | None = None
    executable: bool = False
    arch: str | None = None


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def verify_sha256(path: Path, expected: str) -> None:
    actual = sha256_file(path)
    if actual.lower() != expected.lower():
        raise IntegrityError(f"SHA-256 mismatch for {path.name}: expected {expected}, got {actual}")


def load_manifest(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise IntegrityError("Manifest must be a JSON object")
    if data.get("schema") != 1:
        raise IntegrityError("Unsupported manifest schema")
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise IntegrityError("Manifest must contain artifacts")
    for a in artifacts:
        if not isinstance(a, dict):
            raise IntegrityError("Manifest artifact must be an object")
        for key in ("name", "url", "sha256"):
            if not isinstance(a.get(key), str) or not a[key]:
                raise IntegrityError(f"Manifest artifact missing {key}")
        if not re_hex64(a["sha256"]):
            raise IntegrityError(f"Invalid sha256 for {a.get('name')}")
        if "size" in a and (not isinstance(a["size"], int) or a["size"] < 0):
            raise IntegrityError(f"Invalid size for {a.get('name')}")
        url = a["url"]
        if not (url.startswith("https://") or url.startswith("file://")):
            raise IntegrityError(f"Artifact URL must be https/file: {a.get('name')}")
    return data


def re_hex64(value: str) -> bool:
    return len(value) == 64 and all(c in "0123456789abcdefABCDEF" for c in value)


def verify_artifact(path: Path, artifact: Mapping[str, object]) -> None:
    if not path.exists() or not path.is_file():
        raise IntegrityError(f"Missing artifact file: {path}")
    if path.is_symlink():
        raise IntegrityError(f"Artifact must not be a symlink: {path}")
    size = artifact.get("size")
    if isinstance(size, int):
        actual_size = path.stat().st_size
        if actual_size != size:
            raise IntegrityError(f"Size mismatch for {path.name}: expected {size}, got {actual_size}")
    expected = artifact["sha256"]
    assert isinstance(expected, str)
    verify_sha256(path, expected)
    arch = artifact.get("arch")
    if isinstance(arch, str) and arch:
        # Architecture validation is delegated to caller-provided detector in bootstrap.py
        pass


def safe_extract_zip(zip_path: Path, dest: Path) -> list[Path]:
    import zipfile

    dest = dest.resolve()
    extracted: list[Path] = []
    with zipfile.ZipFile(zip_path) as zf:
        infos = zf.infolist()
        total = sum(i.file_size for i in infos)
        if total > 512 * 1024 * 1024:
            raise IntegrityError("Archive too large")
        for info in infos:
            name = info.filename
            if not name or name.endswith("/"):
                target_dir = (dest / name).resolve()
                if dest not in target_dir.parents and target_dir != dest:
                    raise IntegrityError(f"Unsafe archive path: {name}")
                target_dir.mkdir(parents=True, exist_ok=True)
                continue
            target = (dest / name).resolve()
            if dest not in target.parents:
                raise IntegrityError(f"Archive path traversal: {name}")
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            # Reject symlinks in zip (unix external attrs)
            mode = (info.external_attr >> 16) & 0o170000
            if mode == 0o120000:
                raise IntegrityError(f"Archive symlink not allowed: {name}")
            if info.file_size > 256 * 1024 * 1024:
                raise IntegrityError(f"Archive entry too large: {name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, target.open("wb") as out:
                remaining = info.file_size
                while remaining > 0:
                    chunk = src.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    out.write(chunk)
                    remaining -= len(chunk)
                if remaining != 0:
                    raise IntegrityError(f"Archive entry truncated: {name}")
            extracted.append(target)
    return extracted
