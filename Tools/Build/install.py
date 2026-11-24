"""USB first install from a local, device-signed IPA. Does not request credentials."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile


def bundle_info(ipa):
    with zipfile.ZipFile(ipa) as archive:
        infos = [entry for entry in archive.infolist() if re.fullmatch(
            r'Payload/[^/]+\.app/Info\.plist', entry.filename)]
        if len(infos) != 1 or infos[0].file_size > 1024 * 1024:
            raise ValueError('Expected exactly one app with a bounded Info.plist.')
        info = plistlib.loads(archive.read(infos[0]))
        bundle = info.get('CFBundleIdentifier') if isinstance(info, dict) else None
        if not isinstance(bundle, str) or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
            raise ValueError('Missing or invalid app bundle identifier.')
        root = infos[0].filename.rsplit('/', 1)[0]
        if not all(root + '/' + item in archive.namelist() for item in
                   ('embedded.mobileprovision', '_CodeSignature/CodeResources')):
            raise ValueError('Missing embedded signing material. Supply a device-signed IPA.')
        return info


def inspect(ipa):
    return bundle_info(ipa)["CFBundleIdentifier"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', type=Path, help='Local signed IPA (omit to list USB devices)')
    parser.add_argument('--device', help='Exact identifier printed by the USB device list')
    parser.add_argument('--confirm-install', action='store_true', help='Authorize install/replacement')
    args = parser.parse_args(argv)
    if not args.ipa and (args.device or args.confirm_install):
        parser.error('--device and --confirm-install require --ipa')
    if args.ipa and not args.device:
        parser.error('Select a device explicitly with --device')
    devices = subprocess.run(['idevice_id', '-l'], check=True, capture_output=True, text=True).stdout.splitlines()
    if not args.ipa:
        print('\n'.join(devices) or 'No USB devices found. Unlock the device and trust this computer.')
        return
    if args.device not in devices or not re.fullmatch(r'[0-9A-Fa-f-]{8,64}', args.device):
        raise ValueError('Selected USB device not found. Check the cable, device trust and identifier.')
    path = args.ipa.resolve(strict=True)
    bundle = inspect(path)
    print(f'Install {bundle} on {args.device} from {path}', flush=True)
    if not args.confirm_install:
        print('Preview only. Re-run with --confirm-install to install or replace this app.')
        return
    subprocess.run(['ideviceinstaller', '-u', args.device, 'install', str(path)], check=True)
    print('Installer finished. Open the app on the selected device to verify launch.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException, subprocess.CalledProcessError) as err:
        sys.exit(f'First install failed: {err}')
