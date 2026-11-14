"""Tests for the self-hosted repo store and its HTTP surface.

Run from `Services/API/server/`:

    python -m pytest tests/ -q

The tests build real (tiny) IPAs — a zip with `Payload/App.app/Info.plist` —
so the metadata extraction runs against the same shape the endpoint receives.
"""

from __future__ import annotations

import io
import json
import os
import plistlib
import sys
import zipfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

ADMIN_TOKEN = "test-admin-token"
os.environ["ADMIN_TOKEN"] = ADMIN_TOKEN


@pytest.fixture(autouse=True)
def isolated_store(tmp_path, monkeypatch):
    """Every test gets an empty store folder."""
    monkeypatch.setenv("REPO_STORE_DIR", str(tmp_path / "store"))
    import repo_store

    yield repo_store


def make_ipa(bundle_id: str = "com.example.app", name: str = "Example",
             version: str = "1.2.3", payload: bytes = b"binary") -> bytes:
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleDisplayName": name,
        "CFBundleName": name,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "42",
        "CFBundleExecutable": "Example",
    }
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("Payload/Example.app/Info.plist", plistlib.dumps(info))
        archive.writestr("Payload/Example.app/Example", payload)
        # A nested extension must not win over the app bundle's own plist.
        archive.writestr(
            "Payload/Example.app/PlugIns/Share.appex/Info.plist",
            plistlib.dumps({"CFBundleIdentifier": f"{bundle_id}.share", "CFBundleName": "Share"}),
        )
    return buffer.getvalue()


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------

def test_reads_metadata_from_the_app_bundle(isolated_store, tmp_path):
    ipa = tmp_path / "app.ipa"
    ipa.write_bytes(make_ipa())

    metadata = isolated_store.read_ipa_metadata(ipa)

    assert metadata == {
        "bundle_identifier": "com.example.app",
        "name": "Example",
        "version": "1.2.3",
    }


def test_rejects_files_that_are_not_ipas(isolated_store, tmp_path):
    not_zip = tmp_path / "plain.ipa"
    not_zip.write_bytes(b"this is not a zip")
    with pytest.raises(isolated_store.RepoError, match="not a zip"):
        isolated_store.read_ipa_metadata(not_zip)

    no_app = tmp_path / "empty.ipa"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("readme.txt", "nothing here")
    no_app.write_bytes(buffer.getvalue())
    with pytest.raises(isolated_store.RepoError, match="Info.plist"):
        isolated_store.read_ipa_metadata(no_app)


def test_add_replaces_the_previous_version_and_keeps_the_file(isolated_store, tmp_path):
    first = tmp_path / "v1.ipa"
    first.write_bytes(make_ipa(version="1.0"))
    second = tmp_path / "v2.ipa"
    second.write_bytes(make_ipa(version="2.0"))

    previous = isolated_store.store.add(first)
    previous_path = isolated_store.store.ipa_path(previous)
    app = isolated_store.store.add(second)

    assert app.version == "2.0"
    assert len(isolated_store.store.apps()) == 1
    assert app.size > 0
    assert isolated_store.store.ipa_path(app) is not None
    # Replacing an app must not leave unreachable old IPA versions consuming
    # persistent storage indefinitely.
    assert previous_path is not None and not previous_path.exists()

    # The index survives a fresh read (it is a file, not memory).
    assert isolated_store.RepoStore().apps()[0].version == "2.0"


def test_remove_drops_the_entry_and_the_ipa(isolated_store, tmp_path):
    ipa = tmp_path / "app.ipa"
    ipa.write_bytes(make_ipa())
    app = isolated_store.store.add(ipa)
    stored = isolated_store.store.ipa_path(app)

    assert isolated_store.store.remove(app.bundle_identifier) is True
    assert isolated_store.store.apps() == []
    assert stored is not None and not stored.exists()
    assert isolated_store.store.remove(app.bundle_identifier) is False


def test_malicious_index_filename_cannot_delete_outside_store(isolated_store, tmp_path):
    victim = tmp_path / "important.txt"
    victim.write_text("keep me", encoding="utf-8")
    store_root = isolated_store.store_dir()
    store_root.mkdir(parents=True, exist_ok=True)
    (store_root / "apps.json").write_text(
        json.dumps({"apps": [{
            "bundle_identifier": "com.example.malicious",
            "name": "Malicious", "version": "1", "filename": "../important.txt",
        }]}),
        encoding="utf-8",
    )

    assert isolated_store.store.remove("com.example.malicious") is True
    assert victim.read_text(encoding="utf-8") == "keep me"


def test_source_feed_matches_what_asrepository_decodes(isolated_store, tmp_path):
    ipa = tmp_path / "app.ipa"
    ipa.write_bytes(make_ipa())
    isolated_store.store.add(ipa, developer="Me", subtitle="sub", description="desc")

    feed = isolated_store.source_feed("https://repo.example.com/")

    assert feed["identifier"] and feed["name"]
    assert feed["sourceURL"] == "https://repo.example.com/repo/source.json"
    assert len(feed["apps"]) == 1

    entry = feed["apps"][0]
    # Field names VexSign's AltSourceKit decodes.
    assert entry["bundleIdentifier"] == "com.example.app"
    assert entry["name"] == "Example"
    assert entry["version"] == "1.2.3"
    assert entry["developerName"] == "Me"
    assert entry["downloadURL"] == "https://repo.example.com/static/apps/com.example.app-1.2.3.ipa"
    assert entry["size"] > 0
    assert entry["iconURL"].startswith("https://repo.example.com/")


def test_appdata_xml_is_escaped(isolated_store, tmp_path):
    ipa = tmp_path / "app.ipa"
    ipa.write_bytes(make_ipa(bundle_id="com.example.app", name="A & B <App>"))
    isolated_store.store.add(ipa, description="has <tags> & more")

    xml = isolated_store.appdata_xml("https://repo.example.com")

    assert xml.startswith('<?xml version="1.0" encoding="UTF-8"?>')
    assert "<apps>" in xml and "</apps>" in xml
    assert "A &amp; B &lt;App&gt;" in xml
    assert "has &lt;tags&gt; &amp; more" in xml
    assert "<bundleid>com.example.app</bundleid>" in xml
    assert "<ipaurl>https://repo.example.com/static/apps/com.example.app-1.2.3.ipa</ipaurl>" in xml


# ---------------------------------------------------------------------------
# HTTP surface
# ---------------------------------------------------------------------------

@pytest.fixture
def client(isolated_store):
    import main

    with TestClient(main.app) as test_client:
        yield test_client


def test_source_endpoints_are_public_and_consistent(client, tmp_path):
    ipa = tmp_path / "app.ipa"
    ipa.write_bytes(make_ipa())

    response = client.post(
        "/api/admin/apps",
        files={"file": ("app.ipa", ipa.read_bytes(), "application/octet-stream")},
        headers={"X-Admin-Token": ADMIN_TOKEN},
    )
    assert response.status_code == 200, response.text

    feed = client.get("/repo/source.json")
    assert feed.status_code == 200
    body = feed.json()
    assert body["apps"][0]["bundleIdentifier"] == "com.example.app"

    xml = client.get("/repo/appdata")
    assert xml.status_code == 200
    assert "com.example.app" in xml.text

    download = client.get(body["apps"][0]["downloadURL"].split("localhost")[-1])
    assert download.status_code == 200
    assert download.headers["content-type"] == "application/octet-stream"
    assert len(download.content) == ipa.stat().st_size


def test_ipa_route_refuses_path_traversal(client):
    assert client.get("/static/apps/..%2F..%2Fapps.json").status_code in (400, 404)
    assert client.get("/static/apps/nope.ipa").status_code == 404


def test_upload_requires_the_admin_token(client, tmp_path):
    ipa = tmp_path / "app.ipa"
    ipa.write_bytes(make_ipa())
    payload = {"file": ("app.ipa", ipa.read_bytes(), "application/octet-stream")}

    assert client.post("/api/admin/apps", files=payload).status_code == 403
    assert client.post(
        "/api/admin/apps", files=payload, headers={"X-Admin-Token": "wrong"}
    ).status_code == 403


def test_upload_rejects_a_non_ipa(client):
    response = client.post(
        "/api/admin/apps",
        files={"file": ("app.ipa", b"definitely not an ipa", "application/octet-stream")},
        headers={"X-Admin-Token": ADMIN_TOKEN},
    )
    assert response.status_code == 400
    assert "not a zip" in response.json()["detail"]


def test_upload_replaces_and_delete_removes(client, tmp_path):
    headers = {"X-Admin-Token": ADMIN_TOKEN}

    first = client.post(
        "/api/admin/apps",
        files={"file": ("a.ipa", make_ipa(version="1.0"), "application/octet-stream")},
        headers=headers,
    )
    assert first.status_code == 200
    second = client.post(
        "/api/admin/apps",
        files={"file": ("a.ipa", make_ipa(version="2.0"), "application/octet-stream")},
        headers=headers,
    )
    assert second.status_code == 200
    assert second.json()["app"]["version"] == "2.0"

    listed = client.get("/api/admin/apps", headers=headers).json()["apps"]
    assert len(listed) == 1 and listed[0]["version"] == "2.0"

    removed = client.delete("/api/admin/apps/com.example.app", headers=headers)
    assert removed.status_code == 200
    assert client.get("/api/admin/apps", headers=headers).json()["apps"] == []
    assert client.delete("/api/admin/apps/com.example.app", headers=headers).status_code == 404

    # The public feed is empty again, but still valid JSON.
    assert client.get("/repo/source.json").json()["apps"] == []


def test_feed_still_reports_health_and_root_endpoints(client):
    assert client.get("/api/health").json() == {"status": "ok"}
    public = client.get("/").json()["endpoints"]
    assert any("/repo/source.json" in entry for entry in public)
    # The admin surface is only advertised to an authenticated admin.
    assert not any("/api/admin/apps" in entry for entry in public)
    authed = client.get("/", headers={"X-Admin-Token": ADMIN_TOKEN}).json()["endpoints"]
    assert any("/api/admin/apps" in entry for entry in authed)

    # Browsers get the human-readable status page instead of JSON.
    page = client.get("/", headers={"Accept": "text/html"})
    assert page.status_code == 200
    assert "text/html" in page.headers["content-type"]
    assert "VexSign Premium API" in page.text


def test_key_validation_and_atomic_consumption(client, tmp_path, monkeypatch):
    import db
    monkeypatch.setattr(db, "DB_PATH", str(tmp_path / "test.db"))

    # Mint a key
    db.add_key("VEX-TEST-1234-5678")

    # Device 1 consumes it successfully
    res1 = client.post(
        "/api/validate",
        json={"device_uuid": "device-1"},
        headers={"X-API-Key": "VEX-TEST-1234-5678"},
    )
    assert res1.status_code == 200
    assert "urls" in res1.json()

    # Device 1 re-validates (idempotent)
    res1_again = client.post(
        "/api/validate",
        json={"device_uuid": "device-1"},
        headers={"X-API-Key": "VEX-TEST-1234-5678"},
    )
    assert res1_again.status_code == 200

    # Device 2 tries to use the same key -> rejected (401)
    res2 = client.post(
        "/api/validate",
        json={"device_uuid": "device-2"},
        headers={"X-API-Key": "VEX-TEST-1234-5678"},
    )
    assert res2.status_code == 401
