#!/usr/bin/env python3
"""Prepare/build a source-pinned IDevice with VexSign's modern enrollment ABI.

No Apple account/device operations. No downloaded XCFramework, moving Git ref,
privileged installer, generated secret, or release is used. Outputs are ignored.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import subprocess
import tempfile
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]  # Packages/DeviceBridge -> repository root
WORK = ROOT / '.build/device-bridge'
PRODUCT = ROOT / 'Packages/Vendor/IDeviceKitten/.build/ModernDevice'
LOCK = HERE / 'inputs.lock.json'
FEATURES = 'ring,afc,core_device,core_device_proxy,heartbeat,installation_proxy,springboardservices,syslog_relay,tunnel_tcp_stack,tcp'
TOOLCHAIN = '1.94.0'
TARGETS = {
    'aarch64-apple-ios': 'iphoneos',
    'aarch64-apple-ios-sim': 'iphonesimulator',
    'x86_64-apple-ios': 'iphonesimulator',
    'aarch64-apple-darwin': 'macosx',
    'x86_64-apple-darwin': 'macosx',
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_lock() -> dict:
    record = json.loads(LOCK.read_text())
    if record['schema'] != 1 or len(record['sourceCommit']) != 40:
        raise ValueError('Unreviewed DeviceBridge source lock')
    return record


def fingerprint() -> str:
    return sha(LOCK.read_bytes() + Path(__file__).read_bytes() + (HERE / 'Native/vexsign_device.rs').read_bytes())


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError('Upstream DeviceBridge patch precondition changed')
    return text.replace(old, new, 1)


def patch_sources(files: dict[str, bytes], record: dict) -> dict[str, bytes]:
    """Exact-byte patching, injectable for offline drift/ownership tests."""
    for name, expected in record['reviewedSourceSHA256'].items():
        if name not in files or sha(files[name]) != expected:
            raise ValueError(f'Upstream DeviceBridge source changed: {name}')
    patched = dict(files)
    updates = {
        'ffi/src/lib.rs': ('pub mod util;', '#[cfg(feature = "tunnel_tcp_stack")]\npub mod vexsign_device;\npub mod util;'),
        'ffi/src/tunnel_provider.rs': ('async fn finish_tunnel(', 'pub(crate) async fn finish_tunnel('),
    }
    for name in ('ffi/Cargo.toml', 'idevice/Cargo.toml'):
        # Upstream remote dictionaries/TLV tracing can contain credentials. Compile
        # tracing out in this artifact, regardless of any subscriber in the app.
        updates[name] = ('tracing = { version = "0.1.41" }',
                         'tracing = { version = "0.1.41", features = ["max_level_off", "release_max_level_off"] }')
    for name, (old, new) in updates.items():
        patched[name] = replace_once(files[name].decode(), old, new).encode()
    # These upstream functions are not used by the new ABI, but their exported
    # allocator contract must still be correct in the replacement framework.
    name = 'ffi/src/rp_pairing_file.rs'
    patched[name] = replace_once(files[name].decode(), 'let xml = rpf.to_bytes();',
                                'let xml = rpf.to_bytes().into_boxed_slice();').encode()
    name = 'ffi/src/pairing_host.rs'
    patched[name] = replace_once(files[name].decode(), 'let len = txt.len();',
                                'let mut txt = txt.into_boxed_slice();\n    let len = txt.len();').encode()
    name = 'idevice/src/remote_pairing/socket.rs'
    socket = replace_once(files[name].decode(), 'let x = value.as_bytes();',
        'let x = value.as_bytes();\n        if x.len() > u16::MAX as usize { return Err(IdeviceError::FfiInvalidArg); }')
    socket = replace_once(socket, 'self.inner.read_exact(&mut magic).await?;',
        'self.inner.read_exact(&mut magic).await?;\n            if magic != RPPAIRING_MAGIC { return Err(IdeviceError::FfiInvalidArg); }')
    patched[name] = socket.encode()
    name = 'idevice/src/remote_pairing/mod.rs'
    protocol = replace_once(files[name].decode(), 'let data = tlv::deserialize_tlv8(&data)?;\n\n        if data',
        'let data = tlv::deserialize_tlv8(&data)?;\n        if !data.iter().any(|x| x.tlv_type == tlv::PairingDataComponentType::State && x.data == [2]) {\n            return Err(RemotePairingError::PairVerifyFailed.into());\n        }\n\n        if data')
    protocol = replace_once(protocol, 'debug!("Verify TLV: {data:#?}");',
        'debug!("Verify TLV: {data:#?}");\n        if !data.iter().any(|x| x.tlv_type == tlv::PairingDataComponentType::State && x.data == [4]) {\n            return Err(RemotePairingError::PairVerifyFailed.into());\n        }')
    patched[name] = protocol.encode()
    patched['ffi/src/vexsign_device.rs'] = (HERE / 'Native/vexsign_device.rs').read_bytes()
    return patched


def archive_files(data: bytes, record: dict) -> dict[str, bytes]:
    if len(data) > 8 * 1024 * 1024 or sha(data) != record['archiveSHA256']:
        raise ValueError('DeviceBridge archive checksum/size mismatch')
    files = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        total = 0
        for item in archive.infolist():
            path = PurePosixPath(item.filename)
            mode = item.external_attr >> 16
            if (path.is_absolute() or '..' in path.parts or '\\' in item.filename
                    or not path.parts or path.parts[0] != f"idevice-{record['sourceCommit']}"):
                raise ValueError('Unsafe DeviceBridge archive member')
            if item.is_dir():
                continue
            if stat.S_ISLNK(mode):
                relative = PurePosixPath(*path.parts[1:]).as_posix()
                # The pinned upstream README is the sole documented symlink.
                # Flatten its reviewed in-archive target; create no links.
                expected = record.get('documentationSymlinks', {}).get(relative)
                if expected is None or archive.read(item).decode() != expected['target']:
                    raise ValueError('Unsafe DeviceBridge archive symlink')
                continue
            total += item.file_size
            if total > 32 * 1024 * 1024 or item.file_size > 4 * 1024 * 1024:
                raise ValueError('Oversized DeviceBridge source archive')
            relative = PurePosixPath(*path.parts[1:]).as_posix()
            if relative in files:
                raise ValueError('Duplicate DeviceBridge archive member')
            files[relative] = archive.read(item)
    for relative, entry in record.get('documentationSymlinks', {}).items():
        if relative in files or entry['copyFrom'] not in files:
            raise ValueError('Changed DeviceBridge documentation link contract')
        files[relative] = files[entry['copyFrom']]
    if sha(files.get('LICENSE.txt', b'')) != record['licenseSHA256']:
        raise ValueError('Unreviewed upstream license')
    return files


def safe_work() -> None:
    for folder in (WORK, PRODUCT):
        for part in [folder, *folder.parents]:
            if part.is_relative_to(ROOT) and part.is_symlink():
                raise ValueError('DeviceBridge build paths must not contain symlinks')
        folder.mkdir(parents=True, exist_ok=True)


def prepare(*, download: bool = True) -> Path:
    safe_work()
    record = read_lock()
    cache = WORK / f"{record['sourceCommit']}.zip"
    if not cache.exists():
        if not download:
            raise ValueError('Source archive absent; preparation requires a reviewed download')
        with urllib.request.urlopen(record['archiveURL'], timeout=60) as response:
            data = response.read(8 * 1024 * 1024 + 1)
        archive_files(data, record)
        with tempfile.NamedTemporaryFile(dir=WORK, delete=False) as file:
            file.write(data)
            stage = Path(file.name)
        os.replace(stage, cache)
    files = patch_sources(archive_files(cache.read_bytes(), record), record)
    source = WORK / 'sources' / fingerprint()
    hashes = {name: sha(data) for name, data in files.items()}
    if source.exists():
        if source.is_symlink():
            raise ValueError('DeviceBridge source is a symlink')
        # cbindgen rewrites these two generated headers; all executable Rust,
        # manifest/lock/build inputs, and the upstream notice remain exact.
        for name, expected in hashes.items():
            if name in ('ffi/idevice.h', 'cpp/include/idevice.h'):
                continue
            candidate = source / name
            if candidate.is_symlink() or not candidate.is_file() or sha(candidate.read_bytes()) != expected:
                raise ValueError(f'Prepared DeviceBridge source drift: {name}')
    else:
        source.parent.mkdir(parents=True, exist_ok=True)
        temporary = Path(tempfile.mkdtemp(prefix='stage-', dir=source.parent))
        try:
            for name, data in files.items():
                destination = temporary / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            os.replace(temporary, source)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    (WORK / 'source-provenance.json').write_text(json.dumps({
        'schema': 1, 'inputFingerprint': fingerprint(), 'sourceCommit': record['sourceCommit'],
        'archiveSHA256': record['archiveSHA256'], 'sourceSHA256': hashes,
        'scope': 'source/build provenance, not Apple or physical-device acceptance',
    }, indent=2, sort_keys=True) + '\n')
    return source


def run(arguments: list[str], *, cwd: Path, env: dict | None = None) -> None:
    print('+ ' + ' '.join(arguments), flush=True)
    subprocess.run(arguments, cwd=cwd, env=env, check=True)


def cargo(*arguments: str) -> list[str]:
    return ['rustup', 'run', TOOLCHAIN, 'cargo', *arguments]


def native_tests(source: Path) -> None:
    run(cargo('test', '--locked', '-p', 'idevice-ffi', '--no-default-features',
              '--features', FEATURES, 'vexsign_device::tests', '--', '--test-threads=1'), cwd=source)


def build(source: Path) -> Path:
    if platform.system() != 'Darwin':
        raise ValueError('XCFramework building needs macOS/Xcode; --test is a native-host test only')
    for target, sdk in TARGETS.items():
        run(['rustup', 'target', 'add', '--toolchain', TOOLCHAIN, target], cwd=source)
        sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
        environment = dict(os.environ, BINDGEN_EXTRA_CLANG_ARGS=f'--sysroot={sdk_path}',
                           IPHONEOS_DEPLOYMENT_TARGET='17.0', MACOSX_DEPLOYMENT_TARGET='13.0')
        run(cargo('build', '--locked', '--release', '--target', target, '-p', 'idevice-ffi',
                  '--no-default-features', '--features', FEATURES), cwd=source, env=environment)
    headers = WORK / 'headers'
    headers.mkdir(exist_ok=True)
    shutil.copyfile(source / 'ffi/idevice.h', headers / 'idevice.h')
    (headers / 'module.modulemap').write_text('module IDevice {\n  header "idevice.h"\n  export *\n}\n')
    libraries = []
    for name, targets in (
        ('ios', ['aarch64-apple-ios']),
        ('simulator', ['aarch64-apple-ios-sim', 'x86_64-apple-ios']),
        ('macos', ['aarch64-apple-darwin', 'x86_64-apple-darwin']),
    ):
        output = WORK / f'libidevice-{name}.a'
        inputs = [str(source / f'target/{target}/release/libidevice_ffi.a') for target in targets]
        if len(inputs) == 1:
            shutil.copyfile(inputs[0], output)
        else:
            run(['xcrun', 'lipo', '-create', *inputs, '-output', str(output)], cwd=source)
        libraries += ['-library', str(output), '-headers', str(headers)]
    # Never reuse a partially generated binary as a ready SwiftPM input.
    stage = Path(tempfile.mkdtemp(prefix='framework-', dir=WORK))
    try:
        framework = stage / 'IDevice.xcframework'
        run(['xcodebuild', '-create-xcframework', *libraries, '-output', str(framework)], cwd=ROOT)
        artifacts = {path.relative_to(framework).as_posix(): sha(path.read_bytes())
                     for path in framework.rglob('*') if path.is_file()}
        (stage / 'provenance.json').write_text(json.dumps({
            'schema': 1, 'inputFingerprint': fingerprint(), 'sourceCommit': read_lock()['sourceCommit'],
            'rustToolchain': TOOLCHAIN, 'features': FEATURES, 'artifactSHA256': artifacts,
            'scope': 'unsigned source-built native bridge; no physical-device acceptance',
        }, indent=2, sort_keys=True) + '\n')
        destination = PRODUCT / 'IDevice.xcframework'
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(framework, destination)
        shutil.copyfile(stage / 'provenance.json', PRODUCT / 'provenance.json')
        shutil.copyfile(HERE / 'LICENSE.idevice.txt', PRODUCT / 'LICENSE.idevice.txt')
    finally:
        shutil.rmtree(stage)
    return PRODUCT / 'IDevice.xcframework'


def verify_product() -> bool:
    safe_work()
    path = PRODUCT / 'provenance.json'
    if not path.is_file() or path.is_symlink():
        return False
    record = json.loads(path.read_text())
    if record.get('inputFingerprint') != fingerprint():
        return False
    framework = PRODUCT / 'IDevice.xcframework'
    actual = {p.relative_to(framework).as_posix(): sha(p.read_bytes())
              for p in framework.rglob('*') if p.is_file() and not p.is_symlink()}
    return bool(actual) and actual == record.get('artifactSHA256')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test', action='store_true', help='Run only credential-free native unit tests')
    parser.add_argument('--prepare-only', action='store_true', help='Verify/stage source without compiling')
    parser.add_argument('--build', action='store_true', help='Build/verify the local XCFramework')
    options = parser.parse_args()
    if options.build and verify_product():
        print('Verified existing source-built DeviceBridge: ' + fingerprint())
        return
    source = prepare()
    print('Source-pinned DeviceBridge: ' + str(source))
    if options.prepare_only:
        return
    if not shutil.which('rustup'):
        parser.error(f'Install Rust {TOOLCHAIN} using rustup; no automatic installer is executed')
    if options.test:
        native_tests(source)
    if options.build:
        native_tests(source)
        print('Built: ' + str(build(source)))
    if not options.test and not options.build:
        parser.error('Choose --prepare-only, --test or --build')


if __name__ == '__main__':
    main()
