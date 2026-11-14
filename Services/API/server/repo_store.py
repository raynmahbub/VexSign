#!/usr/bin/env python3
"""Self-hosted AltStore-compatible source, backed by uploaded IPAs.

The premium backend already serves a *gated* feed (``/repo/premium.json``). This
module adds the other half of self-hosting: a store you fill by uploading IPAs,
served publicly so any AltStore-family client — VexSign included — can add it as
a source.

    POST /api/admin/apps          upload an .ipa (admin token), metadata is read
                                  from its Info.plist
    GET  /api/admin/apps          list what is stored
    DELETE /api/admin/apps/{id}   drop an app
    GET  /repo/source.json        AltStore v1 source (what VexSign decodes)
    GET  /repo/appdata            legacy AltServer XML feed
    GET  /static/apps/<file>.ipa  the IPAs themselves

Everything is a JSON file plus a folder of IPAs — no database, so the whole
source survives a container restart as long as ``REPO_STORE_DIR`` is a volume.

Only stdlib is used for IPA inspection: an .ipa is a zip whose
``Payload/<App>.app/Info.plist`` carries the bundle id, name and version.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import threading
import zipfile
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_STORE_DIR = os.path.join(os.path.dirname(__file__), "repo-store")

_SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")


def store_dir() -> Path:
    return Path(os.environ.get("REPO_STORE_DIR") or DEFAULT_STORE_DIR)


def apps_dir() -> Path:
    return store_dir() / "apps"


def index_path() -> Path:
    return store_dir() / "apps.json"


def _stored_ipa_path(filename: str) -> Path | None:
    """Resolve a stored filename without allowing index data to escape apps/."""
    if not filename or Path(filename).name != filename:
        return None
    root = apps_dir().resolve()
    candidate = root / filename
    # Reject symlinks rather than resolving them: removal must unlink only the
    # indexed entry itself, and serving must not follow a link outside apps/.
    if candidate.is_symlink():
        return None
    try:
        return candidate if candidate.resolve(strict=False).parent == root else None
    except OSError:
        return None


# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

@dataclass
class RepoApp:
    """One entry in the source feed."""

    bundle_identifier: str
    name: str
    version: str
    filename: str
    size: int = 0
    developer: str = "VexSign"
    subtitle: str = ""
    description: str = ""
    category: str = "Utilities"
    version_date: str = field(
        default_factory=lambda: datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    )

    @property
    def id(self) -> str:
        return self.bundle_identifier

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @staticmethod
    def from_dict(data: dict[str, Any]) -> "RepoApp":
        known = {key: data[key] for key in RepoApp.__dataclass_fields__ if key in data}
        return RepoApp(**known)


class RepoError(Exception):
    """Raised for anything the API should turn into a 4xx."""


# ---------------------------------------------------------------------------
# IPA inspection
# ---------------------------------------------------------------------------

def read_ipa_metadata(path: Path) -> dict[str, Any]:
    """Pulls bundle id / name / version out of an .ipa without unpacking it."""
    if not zipfile.is_zipfile(path):
        raise RepoError("That file is not a zip archive, so it cannot be an IPA.")

    with zipfile.ZipFile(path) as archive:
        info_names = [
            name
            for name in archive.namelist()
            if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)
        ]
        if not info_names:
            raise RepoError("No Payload/<App>.app/Info.plist found — is this an IPA?")

        # Shallowest match: the app bundle, not a nested extension.
        info_name = sorted(info_names, key=lambda name: name.count("/"))[0]
        try:
            with archive.open(info_name) as handle:
                info = plistlib.load(handle)
        except Exception as exc:  # plistlib raises several types on bad input
            raise RepoError(f"Info.plist could not be parsed: {exc}") from exc

    bundle_id = str(info.get("CFBundleIdentifier") or "").strip()
    if not bundle_id:
        raise RepoError("Info.plist has no CFBundleIdentifier.")

    name = (
        info.get("CFBundleDisplayName")
        or info.get("CFBundleName")
        or bundle_id.rsplit(".", 1)[-1]
    )
    version = str(
        info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "1.0"
    )

    return {"bundle_identifier": bundle_id, "name": str(name), "version": version}


def _safe_filename(bundle_id: str, version: str) -> str:
    stem = _SAFE_NAME.sub("_", f"{bundle_id}-{version}") or "app"
    return f"{stem}.ipa"


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------

class RepoStore:
    """JSON index + IPA folder. Writes are serialised; reads are lock-free."""

    def __init__(self) -> None:
        self._lock = threading.Lock()

    # -- index -------------------------------------------------------------

    def _load(self) -> list[RepoApp]:
        path = index_path()
        if not path.exists():
            return []
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []
        apps = raw.get("apps") if isinstance(raw, dict) else raw
        if not isinstance(apps, list):
            return []
        result: list[RepoApp] = []
        for entry in apps:
            if isinstance(entry, dict):
                try:
                    result.append(RepoApp.from_dict(entry))
                except TypeError:
                    continue
        return result

    def _save(self, apps: list[RepoApp]) -> None:
        apps_dir().mkdir(parents=True, exist_ok=True)
        payload = {
            "version": 1,
            "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "apps": [app.to_dict() for app in apps],
        }
        tmp = index_path().with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        tmp.replace(index_path())

    # -- public API --------------------------------------------------------

    def apps(self) -> list[RepoApp]:
        return sorted(self._load(), key=lambda app: app.name.lower())

    def app(self, bundle_id: str) -> RepoApp | None:
        return next((a for a in self._load() if a.bundle_identifier == bundle_id), None)

    def add(self, source: Path, *, developer: str | None = None,
            subtitle: str | None = None, description: str | None = None,
            category: str | None = None) -> RepoApp:
        """Stores an uploaded IPA and indexes it, replacing an older version."""
        metadata = read_ipa_metadata(source)
        filename = _safe_filename(metadata["bundle_identifier"], metadata["version"])
        destination = apps_dir() / filename

        with self._lock:
            apps_dir().mkdir(parents=True, exist_ok=True)
            previous_apps = self._load()
            shutil.copyfile(source, destination)

            apps = [
                app for app in previous_apps
                if app.bundle_identifier != metadata["bundle_identifier"]
            ]
            app = RepoApp(
                bundle_identifier=metadata["bundle_identifier"],
                name=metadata["name"],
                version=metadata["version"],
                filename=filename,
                size=destination.stat().st_size,
                developer=developer or "VexSign",
                subtitle=subtitle or "",
                description=description or "",
                category=category or "Utilities",
            )
            apps.append(app)
            # Persist the new index before pruning old versions. If saving fails,
            # the previous index and IPA remain usable; after success, remove only
            # files no longer referenced by any app entry (including malformed or
            # duplicate index entries for another bundle).
            self._save(apps)
            referenced = {entry.filename for entry in apps}
            for old_app in previous_apps:
                if old_app.filename != filename and old_app.filename not in referenced:
                    old_path = _stored_ipa_path(old_app.filename)
                    if old_path is not None:
                        try:
                            old_path.unlink()
                        except OSError:
                            pass

        return app

    def remove(self, bundle_id: str) -> bool:
        with self._lock:
            apps = self._load()
            remaining = [app for app in apps if app.bundle_identifier != bundle_id]
            if len(remaining) == len(apps):
                return False

            self._save(remaining)
            referenced = {app.filename for app in remaining}
            for app in apps:
                if app.bundle_identifier == bundle_id and app.filename not in referenced:
                    path = _stored_ipa_path(app.filename)
                    if path is not None:
                        try:
                            path.unlink()
                        except OSError:
                            pass
            return True

    def ipa_path(self, app: RepoApp) -> Path | None:
        path = _stored_ipa_path(app.filename)
        return path if path is not None and path.is_file() else None


store = RepoStore()


# ---------------------------------------------------------------------------
# Feeds
# ---------------------------------------------------------------------------

def source_feed(base_url: str, *, name: str | None = None,
                identifier: str | None = None) -> dict[str, Any]:
    """AltStore v1 source — the exact shape `ASRepository` decodes."""
    base = base_url.rstrip("/")
    apps = []
    for app in store.apps():
        apps.append(
            {
                "name": app.name,
                "bundleIdentifier": app.bundle_identifier,
                "developerName": app.developer,
                "subtitle": app.subtitle,
                "description": app.description,
                "version": app.version,
                "versionDate": app.version_date,
                "downloadURL": f"{base}/static/apps/{app.filename}",
                "iconURL": f"{base}/static/icon.png",
                "size": app.size,
                "category": app.category,
            }
        )

    return {
        "name": name or os.environ.get("REPO_SOURCE_NAME") or "VexSign Self-Hosted",
        "identifier": identifier
        or os.environ.get("REPO_SOURCE_IDENTIFIER")
        or "com.vexsign.selfhosted",
        "subtitle": os.environ.get("REPO_SOURCE_SUBTITLE") or "Hosted with VexSign",
        "iconURL": f"{base}/static/icon.png",
        "sourceURL": f"{base}/repo/source.json",
        "apps": apps,
    }


def _escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def appdata_xml(base_url: str) -> str:
    """Legacy AltServer ``appdata`` XML, for clients that never moved to JSON."""
    base = base_url.rstrip("/")
    parts = ['<?xml version="1.0" encoding="UTF-8"?>', "<apps>"]
    for app in store.apps():
        parts.append("  <app>")
        parts.append(f"    <title>{_escape(app.name)}</title>")
        parts.append(f"    <bundleid>{_escape(app.bundle_identifier)}</bundleid>")
        parts.append(f"    <version>{_escape(app.version)}</version>")
        parts.append(f"    <ipaurl>{_escape(f'{base}/static/apps/{app.filename}')}</ipaurl>")
        parts.append(f"    <screenshoturl>{_escape(f'{base}/static/icon.png')}</screenshoturl>")
        parts.append(f"    <description>{_escape(app.description or app.subtitle)}</description>")
        parts.append("  </app>")
    parts.append("</apps>")
    return "\n".join(parts) + "\n"
