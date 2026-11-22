"""Prepare a static HTTPS first-install site for an already provisioned IPA."""
import argparse
from html import escape
from pathlib import Path
import plistlib
import re
import shutil
import sys
from urllib.parse import quote, urlsplit
import zipfile

from install import bundle_info


def build(ipa, destination, base):
    url = urlsplit(base)
    if (url.scheme != 'https' or not url.hostname or url.username is not None
            or url.password is not None or url.query or url.fragment
            or any(ord(ch) < 33 or ord(ch) > 126 or ch == '\\' for ch in base)):
        raise ValueError('Use the final HTTPS directory URL without credentials, query or fragment.')
    _ = url.port  # reject malformed ports before writing anything
    base = base.rstrip('/') + '/'
    destination.mkdir()  # Never overwrite an earlier deployment or an input file.
    try:
        package = destination / 'app.ipa'
        shutil.copyfile(ipa, package)
        info = bundle_info(package)  # inspect the exact bytes we will publish
        bundle = info['CFBundleIdentifier']
        version = info.get('CFBundleVersion')
        if not isinstance(version, str) or not re.fullmatch(r'[A-Za-z0-9.-]{1,64}', version):
            raise ValueError('The IPA has no usable CFBundleVersion.')
        name = info.get('CFBundleDisplayName') or info.get('CFBundleName') or bundle
        if not isinstance(name, str):
            raise ValueError('Invalid application name.')
        manifest = {'items': [{'assets': [{'kind': 'software-package', 'url': base + 'app.ipa'}],
                               'metadata': {'kind': 'software', 'bundle-identifier': bundle,
                                            'bundle-version': version, 'title': name}}]}
        (destination / 'manifest.plist').write_bytes(plistlib.dumps(manifest))
        link = 'itms-services://?action=download-manifest&url=' + quote(base + 'manifest.plist', safe='')
        (destination / 'index.html').write_text(f'''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Install {escape(name)}</title><main><h1>Install {escape(name)}</h1>
<p>{escape(bundle)} · Build {escape(version)}</p>
<p>Open this page in Safari on a device authorized by the signing profile.</p>
<p><a href="{escape(link)}">Install {escape(name)}</a></p>
<p>Confirm the iOS installation prompt, then open the app from your Home Screen.
If installation fails, ask your distributor to check profile validity and device eligibility.</p>
</main></html>''', encoding='utf-8')
    except BaseException:
        shutil.rmtree(destination)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path, help='New local directory')
    parser.add_argument('--base-url', required=True, help='Final HTTPS directory URL')
    args = parser.parse_args()
    try:
        build(args.ipa, args.output, args.base_url)
    except (ValueError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        sys.exit(f'Site not generated: {error}')
    print(f'Upload the contents of {args.output} to {args.base_url}. Nothing has been published.')
