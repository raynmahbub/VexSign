#!/usr/bin/env python3
"""Build an upstream-derived LiveContainer host with embedded SideStore/VexSign.

No floating downloads, account credentials, provisioning profiles, or TLS keys.
The produced IPA is ad-hoc: install/re-sign using the official host's supported
workflow. This does not grant entitlements or bypass JIT/signing requirements.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
HERE = ROOT / "EmbeddedContainer"
MAX_EXPANDED = 8 * 1024**3


def run(*args, cwd=None):
    print("+", *map(str, args), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, check=True)


def output(*args, cwd=None):
    return subprocess.check_output(list(map(str, args)), cwd=cwd, text=True).strip()


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_digest(path, expected):
    if len(expected) != 64 or sha256(path) != expected:
        raise ValueError(f"SHA-256 mismatch for {Path(path).name}; refusing this input")


def fetch_asset(spec, destination):
    # IDs fail closed if an upstream nightly is replaced/deleted. No tag fallback.
    if not destination.exists():
        temporary = destination.with_suffix(".download")
        try:
            with temporary.open("wb") as f:
                subprocess.run(["gh", "api", f"repos/{spec['repository']}/releases/assets/{spec['asset_id']}",
                                "-H", "Accept: application/octet-stream"], stdout=f, check=True)
            verify_digest(temporary, spec["sha256"])
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)
    verify_digest(destination, spec["sha256"])
    return destination


def extract_zip(source, destination):
    """Reject traversal, duplicate files, symlinks and oversized archives first."""
    destination = Path(destination).resolve()
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        if len(entries) > 50000 or sum(x.file_size for x in entries) > MAX_EXPANDED:
            raise ValueError("Archive exceeds extraction limits")
        seen = set()
        for entry in entries:
            raw = entry.filename.replace("\\", "/")
            parts = raw.rstrip("/").split("/")
            if (not raw or raw.startswith(("/", "~")) or "\0" in raw
                    or any(p in ("", ".", "..") or ":" in p for p in parts)
                    or stat.S_ISLNK(entry.external_attr >> 16)):
                raise ValueError(f"Unsafe archive entry: {raw!r}")
            target = destination.joinpath(*PurePosixPath(raw).parts).resolve()
            if destination not in target.parents:
                raise ValueError("Archive escapes its destination")
            if target in seen and not entry.is_dir():
                raise ValueError("Duplicate archive file")
            seen.add(target)
        for entry in entries:
            target = destination.joinpath(*PurePosixPath(entry.filename.replace("\\", "/")).parts)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as src, target.open("xb") as dst:
                    shutil.copyfileobj(src, dst)
                target.chmod((entry.external_attr >> 16) & 0o777 or 0o644)


def app_in(payload):
    apps = sorted(payload.glob("*.app"))
    if len(apps) != 1:
        raise ValueError("Expected exactly one Payload/*.app")
    return apps[0]


def read_plist(path):
    with Path(path).open("rb") as f:
        return plistlib.load(f)


def write_plist(path, value):
    with Path(path).open("wb") as f:
        plistlib.dump(value, f)


def macho_filetypes(path):
    data = Path(path).read_bytes()

    def thin(offset, size):
        magic = data[offset:offset + 4]
        endian = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">",
                  b"\xce\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xce": ">"}.get(magic)
        if not endian or size < 28 or offset + size > len(data):
            raise ValueError("Invalid Mach-O slice")
        return struct.unpack_from(endian + "I", data, offset + 12)[0]

    magic = data[:4]
    fat = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
           b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}.get(magic)
    if not fat:
        return [thin(0, len(data))]
    endian, wide = fat
    if len(data) < 8:
        raise ValueError("Truncated fat header")
    count = struct.unpack_from(endian + "I", data, 4)[0]
    stride = 32 if wide else 20
    if not 0 < count <= 64 or len(data) < 8 + count * stride:
        raise ValueError("Invalid fat slice table")
    types = []
    ranges = []
    for i in range(count):
        off, size = struct.unpack_from(endian + ("QQ" if wide else "II"), data, 8 + i * stride + 8)
        if off < 8 + count * stride or any(off < b and off + size > a for a, b in ranges):
            raise ValueError("Overlapping Mach-O slices")
        types.append(thin(off, size))
        ranges.append((off, off + size))
    return types


def strip_signatures(app):
    for path in sorted(app.rglob("_CodeSignature"), reverse=True):
        if path.is_dir():
            shutil.rmtree(path)
    for path in app.rglob("embedded.mobileprovision"):
        path.unlink()


def zip_tree(root, destination):
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(root.rglob("*")):
            if path.is_symlink():
                raise ValueError(f"Unexpected symlink in package: {path}")
            z.write(path, path.relative_to(root).as_posix() + ("/" if path.is_dir() else ""))


def prepare_guest(source_ipa, work):
    guest_root = work / "guest"
    extract_zip(source_ipa, guest_root)
    guest = app_in(guest_root / "Payload")
    info = read_plist(guest / "Info.plist")
    if info.get("CFBundleIdentifier") != "com.vexsign.app" or info.get("CFBundleExecutable") != "VexSign":
        raise ValueError("The embedded guest must be the VexSign app")
    # These extensions cannot run as guest extensions; retain them in the normal build.
    for name in ("PlugIns", "Watch", "AppClips"):
        path = guest / name
        if path.exists():
            shutil.rmtree(path)
    info["VexSignEmbeddedGuest"] = True
    write_plist(guest / "Info.plist", info)
    strip_signatures(guest)
    archive = work / "VexSign.ipa"
    zip_tree(guest_root, archive)
    return archive, info


def configure_host_info(host, guest_info):
    info = read_plist(host / "Info.plist")
    if info["CFBundleIdentifier"] != "com.kdt.livecontainer":
        raise ValueError("Unsupported host bundle identity; audit runtime/SideStore constants before renaming")
    info["CFBundleDisplayName"] = "VexSign Container"
    info["VexSignCombinedHost"] = True
    # Keep upstream runtime identities, app groups and URL ownership consistent.
    info["ALTAppGroups"] = list(dict.fromkeys(info.get("ALTAppGroups", []) + ["group.com.SideStore.SideStore"]))
    urls = info.setdefault("CFBundleURLTypes", [])
    for scheme in ("sidestore", "sidestore-com.kdt.livecontainer"):
        if not any(scheme in entry.get("CFBundleURLSchemes", []) for entry in urls):
            urls.append({"CFBundleURLName": "com.kdt.livecontainer." + scheme, "CFBundleURLSchemes": [scheme]})
    for entry in guest_info.get("CFBundleURLTypes", []):
        existing = {scheme for item in urls for scheme in item.get("CFBundleURLSchemes", [])}
        schemes = [scheme for scheme in entry.get("CFBundleURLSchemes", []) if scheme not in existing]
        if schemes:
            urls.append(dict(entry, CFBundleURLSchemes=schemes))
    info["LSApplicationQueriesSchemes"] = list(dict.fromkeys(info.get("LSApplicationQueriesSchemes", []) + guest_info.get("LSApplicationQueriesSchemes", [])))
    for key, values in {"INIntentsSupported": ["RefreshAllIntent", "ViewAppIntent"],
                        "NSUserActivityTypes": ["RefreshAllIntent", "ViewAppIntent"]}.items():
        info[key] = list(dict.fromkeys(info.get(key, []) + values))
    version_key = lambda value: tuple(int(x) for x in value.split("."))
    info["MinimumOSVersion"] = max(info.get("MinimumOSVersion", "0"), guest_info.get("MinimumOSVersion", "0"), key=version_key)
    for key, value in guest_info.items():
        if key.startswith("NS") and key.endswith("UsageDescription"):
            info.setdefault(key, value)
    info["NSBonjourServices"] = list(dict.fromkeys(info.get("NSBonjourServices", []) + guest_info.get("NSBonjourServices", [])))
    write_plist(host / "Info.plist", info)
    settings_path = host / "Settings.bundle/Root.plist"
    settings = read_plist(settings_path)
    if not any(x.get("Key") == "LCOpenSideStore" for x in settings["PreferenceSpecifiers"]):
        settings["PreferenceSpecifiers"].append({"Type": "PSToggleSwitchSpecifier", "Title": "Open SideStore", "Key": "LCOpenSideStore", "DefaultValue": False})
    write_plist(settings_path, settings)


def embed_sidestore(host, sidestore_ipa, upstream, dylibify, work):
    extract_zip(sidestore_ipa, work / "sidestore")
    source = app_in(work / "sidestore/Payload")
    info = read_plist(source / "Info.plist")
    executable = info["CFBundleExecutable"]
    if executable != "SideStore":
        raise ValueError("Unexpected SideStore executable")
    target = host / "Frameworks/SideStoreApp.framework"
    shutil.move(source, target)
    strip_signatures(target)
    converted = target / (executable + ".dylib")
    run(dylibify, target / executable, converted)
    if set(macho_filetypes(converted)) != {6}:  # MH_DYLIB in every architecture
        raise ValueError("dylibify did not produce a loadable dylib")
    converted.replace(target / executable)
    run("ldid", "-S", target / executable)
    shutil.copy2(upstream / ".github/sidelc/LCAppInfo.plist", target / "LCAppInfo.plist")
    for name in ("Intents.intentdefinition", "ViewApp.intentdefinition", "Metadata.appintents"):
        src = target / name
        if not src.exists():
            raise ValueError(f"SideStore is missing required intent metadata: {name}")
        if src.is_dir():
            shutil.copytree(src, host / name, dirs_exist_ok=True)
        else:
            shutil.copy2(src, host / name)
    metadata = host / "Metadata.appintents/extract.actionsdata"
    data = metadata.read_bytes()
    for old, new in [(b"9SideStore20RefreshAllAppsIntentV", b"16SideStoreSupport20RefreshAllAppsIntentV"),
                     (b"9SideStore26RefreshAllAppsWidgetIntentV", b"16SideStoreSupport26RefreshAllAppsWidgetIntentV")]:
        if old not in data:
            raise ValueError("SideStore AppIntent ABI changed; review the pinned support framework")
        data = data.replace(old, new)
    metadata.write_bytes(data)
    widget = target / "PlugIns/AltWidgetExtension.appex"
    destination = host / "PlugIns/LiveWidgetExtension.appex"
    if not widget.exists():
        raise ValueError("SideStore widget is missing")
    destination.parent.mkdir(exist_ok=True)
    shutil.move(widget, destination)
    widget_info = read_plist(destination / "Info.plist")
    old_exe = widget_info["CFBundleExecutable"]
    widget_info.update(CFBundleIdentifier="com.kdt.livecontainer.LiveWidget", CFBundleExecutable="LiveWidgetExtension")
    (destination / old_exe).rename(destination / "LiveWidgetExtension")
    write_plist(destination / "Info.plist", widget_info)
    run("ldid", "-S" + str(upstream / ".github/sidelc/LiveWidgetExtension_adhoc.xml"), destination / "LiveWidgetExtension")


def ad_hoc_sign(host, upstream, work):
    # Sign Mach-O leaves without propagating app entitlements into frameworks.
    magics = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
              b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    for path in sorted(host.rglob("*")):
        if path.is_file():
            with path.open("rb") as f:
                magic = f.read(4)
            if magic in magics:
                run("ldid", "-S", path)
    sources = {host: upstream / "entitlements.xml",
               host / "PlugIns/LiveProcess.appex": upstream / "LiveProcess/LiveProcess.entitlements",
               host / "PlugIns/LaunchAppExtension.appex": upstream / "LaunchAppExtension/LaunchAppExtension.entitlements",
               host / "PlugIns/ShareExtension.appex": upstream / "ShareExtension/ShareExtension.entitlements",
               host / "PlugIns/LiveWidgetExtension.appex": upstream / ".github/sidelc/LiveWidgetExtension_adhoc.xml"}
    for index, (bundle, source) in enumerate(sources.items()):
        info = read_plist(bundle / "Info.plist")
        text = source.read_text()
        substitutions = {"DEVELOPMENT_TEAM": "AAAAA11111", "PRODUCT_BUNDLE_IDENTIFIER": info["CFBundleIdentifier"],
                         "APP_GROUP_SIDESTORE": "group.com.SideStore.SideStore", "APP_GROUP_ALTSTORE": "group.com.rileytestut.AltStore",
                         "AppIdentifierPrefix": "AAAAA11111."}
        for key, value in substitutions.items():
            text = text.replace("$(" + key + ")", value)
        if "$(" in text:
            raise ValueError("Unexpanded entitlement variable")
        entitlement = work / f"entitlements-{index}.plist"
        entitlement.write_text(text)
        plistlib.loads(entitlement.read_bytes())
        run("ldid", "-S" + str(entitlement), bundle / info["CFBundleExecutable"])


def validate_payload(host):
    required = ["Frameworks/SideStoreSupport.framework/SideStoreSupport",
                "Frameworks/LiveContainerShared.framework/LiveContainerShared",
                "Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI",
                "Frameworks/SideStoreApp.framework/SideStore", "PlugIns/LiveProcess.appex",
                "PlugIns/LaunchAppExtension.appex", "PlugIns/ShareExtension.appex",
                "PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension", "VexSign.ipa", "VexSignEmbedded.json"]
    for relative in required:
        if not (host / relative).exists():
            raise ValueError(f"Combined runtime is incomplete: {relative}")
    info = read_plist(host / "Info.plist")
    executable = info.get("CFBundleExecutable", "")
    if not isinstance(executable, str) or not executable or PurePosixPath(executable).name != executable:
        raise ValueError("Host executable name is invalid")
    binary = host / executable
    if not binary.is_file() or binary.is_symlink() or set(macho_filetypes(binary)) != {2}:
        raise ValueError("Host executable is not MH_EXECUTE")
    for framework in ("SideStoreSupport", "LiveContainerShared", "LiveContainerSwiftUI", "SideStoreApp"):
        name = "SideStore" if framework == "SideStoreApp" else framework
        if set(macho_filetypes(host / f"Frameworks/{framework}.framework/{name}")) != {6}:
            raise ValueError(f"Embedded {framework} is not MH_DYLIB")
    manifest = json.loads((host / "VexSignEmbedded.json").read_text())
    verify_digest(host / "VexSign.ipa", manifest["sha256"])
    if not read_plist(host / "Info.plist").get("VexSignCombinedHost"):
        raise ValueError("Host marker missing")


def source_notices(host, upstream, lock):
    folder = host / "VexSignSources"
    folder.mkdir()
    shutil.copy2(ROOT / "LICENSE", folder / "VexSign-GPL-3.0.txt")
    shutil.copy2(upstream / "LICENSE", folder / "LiveContainer-AGPL-3.0.txt")
    for name in ("sidestore", "dylibify"):
        spec = lock[name]
        raw = output("gh", "api", f"repos/{spec['repository']}/contents/{spec['license_path']}?ref={spec['commit']}", "--jq", ".content")
        (folder / (name + "-LICENSE.txt")).write_bytes(base64.b64decode(raw))
    provenance = {"inputs": lock, "vexsign_commit": output("git", "rev-parse", "HEAD", cwd=ROOT),
                  "vexsign_source": "https://github.com/raynmahbub/VexSign", "integration": "EmbeddedContainer",
                  "submodules": output("git", "submodule", "status", "--recursive", cwd=upstream),
                  "distribution": "Combined host: AGPL-3.0; retain individual component notices. Publish corresponding source with binaries."}
    (folder / "manifest.json").write_text(json.dumps(provenance, indent=2) + "\n")
    shutil.copy2(HERE / "README.md", folder / "README.md")


def write_build_metadata(ipa, sources, lock):
    """Identify experimental outputs without claiming device acceptance."""
    ipa, sources = Path(ipa), Path(sources)
    metadata = ipa.with_suffix(".build.json")
    checksums = ipa.with_suffix(".checksums.txt")
    files = [{"name": path.name, "sha256": sha256(path), "bytes": path.stat().st_size}
             for path in (ipa, sources)]
    report = {"schemaVersion": 1, "kind": "experimental-guest-host",
              "validation": {"packaging": "structural-checks-only", "physicalDevice": "not-run"},
              "inputs": lock, "files": files,
              "integrationPatchSHA256": sha256(HERE / "patches/combined-host.patch")}
    metadata.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    checksums.write_text("".join(f"{sha256(path)}  {path.name}\n" for path in (ipa, sources, metadata)))
    return metadata, checksums


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vexsign-ipa", required=True, type=Path, help="Normal VexSign arm64 IPA (input remains untouched)")
    parser.add_argument("--work", type=Path, default=ROOT / ".build/embedded-container")
    parser.add_argument("--output", type=Path, default=ROOT / "packages/VexSign+LiveContainer+SideStore.ipa")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native packaging requires macOS, Xcode 26.2+, gh and ldid")
    for tool in ("xcodebuild", "git", "gh", "ldid"):
        if not shutil.which(tool):
            parser.error(f"Missing tool: {tool}")
    lock = json.loads((HERE / "inputs.lock.json").read_text())
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    # Fresh per-build staging; caches are immutable and hash checked on every run.
    with tempfile.TemporaryDirectory(prefix="build-", dir=work) as temporary:
        stage = Path(temporary)
        upstream = stage / "LiveContainer"
        run("git", "clone", "--no-checkout", lock["livecontainer"]["repository"], upstream)
        run("git", "-C", upstream, "checkout", "--detach", lock["livecontainer"]["commit"])
        run("git", "-C", upstream, "submodule", "update", "--init", "--recursive")
        patch = HERE / "patches/combined-host.patch"
        run("git", "-C", upstream, "apply", "--check", patch)
        run("git", "-C", upstream, "apply", patch)
        shutil.copy2(HERE / "HostOverlay/VexSignHostPanel.swift", upstream / "LiveContainerSwiftUI/Views/AppList/VexSignHostPanel.swift")
        sidestore = fetch_asset(lock["sidestore"], work / "SideStore.ipa")
        # Build the pinned converter for the runner architecture rather than
        # executing an opaque release binary that may require a different CPU.
        converter_source = stage / "dylibify-source"
        converter = lock["dylibify"]
        run("git", "clone", "--no-checkout", "https://github.com/" + converter["repository"] + ".git", converter_source)
        run("git", "-C", converter_source, "checkout", "--detach", converter["commit"])
        for relative, digest in converter["source_sha256"].items():
            verify_digest(converter_source / relative, digest)
        dylibify = stage / "dylibify"
        run("xcrun", "--sdk", "macosx", "clang", converter_source / "main.m", "-framework", "Foundation", "-fobjc-arc", "-o", dylibify)
        run("xcodebuild", "archive", "-project", upstream / "LiveContainer.xcodeproj", "-scheme", "LiveContainer",
            "-configuration", "Release", "-sdk", "iphoneos", "-arch", "arm64", "-archivePath", stage / "Host.xcarchive",
            "-derivedDataPath", stage / "DerivedData", "CODE_SIGNING_ALLOWED=NO")
        payload = stage / "combined/Payload"
        payload.mkdir(parents=True)
        host = payload / "LiveContainer.app"
        shutil.copytree(stage / "Host.xcarchive/Products/Applications/LiveContainer.app", host, symlinks=True)
        strip_signatures(host)
        guest_archive, guest_info = prepare_guest(args.vexsign_ipa.resolve(), stage)
        shutil.copy2(guest_archive, host / "VexSign.ipa")
        manifest = {"bundleIdentifier": guest_info["CFBundleIdentifier"], "version": guest_info["CFBundleShortVersionString"],
                    "build": guest_info["CFBundleVersion"], "sha256": sha256(guest_archive)}
        (host / "VexSignEmbedded.json").write_text(json.dumps(manifest, indent=2) + "\n")
        embed_sidestore(host, sidestore, upstream, dylibify, stage)
        configure_host_info(host, guest_info)
        source_notices(host, upstream, lock)
        # Match the official ad-hoc widget/converted executable packaging. The
        # authorized installer must re-sign the complete host and its extensions.
        ad_hoc_sign(host, upstream, stage)
        validate_payload(host)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary_output = stage / "combined.ipa"
        zip_tree(host.parent.parent, temporary_output)
        shutil.copy2(temporary_output, args.output)
        # Ship first-party integration sources beside the IPA; upstream inputs
        # and all transitive submodule commits are recorded in the bundled manifest.
        sources = args.output.with_suffix(".integration-sources.tar.gz")
        with tarfile.open(sources, "w:gz") as archive:
            archive.add(HERE, arcname="EmbeddedContainer", filter=lambda x: None if "__pycache__" in x.name else x)
            archive.add(host / "VexSignSources", arcname="VexSignSources")
        metadata, checksums = write_build_metadata(args.output, sources, lock)
        print(f"Created {args.output}\nSHA-256 {sha256(args.output)}\nIntegration sources: {sources}"
              f"\nBuild metadata: {metadata}\nChecksums: {checksums}")


if __name__ == "__main__":
    main()
