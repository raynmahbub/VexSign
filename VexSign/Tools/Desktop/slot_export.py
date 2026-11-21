"""Back up or return one app-generated export on an authorized development device.

No uninstall, Keychain access, full-container claims or automatic slot eviction.
Requires macOS, Xcode devicectl, and a paired device permitting appDataContainer access.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid


def component(value, pattern):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise ValueError('Invalid device, bundle identifier or export filename')
    return value


def fingerprint(path):
    if not stat.S_ISREG(path.lstat().st_mode) or not path.stat().st_size:
        raise ValueError('Expected a nonempty regular file, not a directory or link')
    size, digest = 0, hashlib.sha256()
    with path.open('rb') as f:
        while chunk := f.read(1024 * 1024):
            size += len(chunk)
            digest.update(chunk)
    return size, digest.hexdigest()


def transfer(direction, device, bundle, src, dst):
    subprocess.run(['xcrun', 'devicectl', 'device', 'copy', direction, '--device', device,
                    '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                    '--source', str(src), '--destination', str(dst)], check=True)


def run(mode, device, bundle, folder, name=None, confirm=False, copy=transfer):
    component(device, r'[0-9A-Fa-f-]{8,64}')
    component(bundle, r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+')
    if mode == 'backup':
        component(name, r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}')
        folder.mkdir(mode=0o700)  # exclusive; never clobber another snapshot
        try:
            payload = folder / 'payload'
            copy('from', device, bundle, f'Documents/{name}', payload)
            size, digest = fingerprint(payload)
            # Read the device again: a changing source or interrupted transfer is not a snapshot.
            with tempfile.TemporaryDirectory() as tmp:
                check = Path(tmp) / 'readback'
                copy('from', device, bundle, f'Documents/{name}', check)
                if fingerprint(check) != (size, digest):
                    raise ValueError('Export changed during backup')
            record = dict(schema=1, device=device, bundle=bundle, name=name, size=size, sha256=digest)
            (folder / 'snapshot.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
        except BaseException:
            shutil.rmtree(folder)
            raise
        return 'Saved and compared two reads of the export. App data restoration is not yet verified.'
    if mode != 'restore' or not confirm:
        raise ValueError('Returning an export to the device requires restore --confirm-restore')
    meta = folder / 'snapshot.json'
    if not stat.S_ISREG(meta.lstat().st_mode) or meta.stat().st_size > 4096:
        raise ValueError('Invalid snapshot metadata')
    record = json.loads(meta.read_text(encoding='utf-8'))
    if not isinstance(record, dict) or (record.get('schema'), record.get('device'), record.get('bundle')) != (1, device, bundle):
        raise ValueError('Snapshot does not match this device and app')
    name = component(record.get('name'), r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}')
    expected = (record.get('size'), record.get('sha256'))
    # Preserve existing documents and the original suffix for the receiving app’s importer.
    dest = f'Documents/VexSign-{uuid.uuid4().hex}-{name}'
    with tempfile.TemporaryDirectory() as tmp:
        staged = Path(tmp) / 'payload'
        shutil.copyfile(folder / 'payload', staged, follow_symlinks=False)
        if fingerprint(staged) != expected:
            raise ValueError('Snapshot payload differs from the recorded export')
        copy('to', device, bundle, staged, dest)
        check = Path(tmp) / 'readback'
        copy('from', device, bundle, dest, check)
        if fingerprint(check) != expected:
            raise ValueError('Returned file could not be verified; retain the snapshot')
    return f'Verified returned bytes at {dest}. Import that file inside the app and verify its contents.'


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    modes = p.add_subparsers(dest='mode', required=True)
    for mode in ('backup', 'restore'):
        sub = modes.add_parser(mode)
        sub.add_argument('--device', required=True)
        sub.add_argument('--bundle', required=True)
        sub.add_argument('--snapshot', type=Path, required=True)
        if mode == 'backup':
            sub.add_argument('--name', required=True, help='Existing export file in the app’s Documents directory')
        else:
            sub.add_argument('--confirm-restore', action='store_true')
    args = p.parse_args()
    try:
        print(run(args.mode, args.device, args.bundle, args.snapshot, getattr(args, 'name', None), getattr(args, 'confirm_restore', False)))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        sys.exit(f'Export operation failed: {exc}')
