"""Join a device observation to the exact exported IPA (macOS security cms)."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile


def convert(row, ipa, decode):
    if not isinstance(row, dict) or not all(isinstance(row.get(k), str) and re.fullmatch('[a-f0-9]{64}', row[k])
                                            for k in ('marker_sha256', 'profile_sha256')):
        raise ValueError('Invalid fixture observation')
    with zipfile.ZipFile(ipa) as archive:
        def member(pattern, limit):
            matches = [e for e in archive.infolist() if re.fullmatch(pattern, e.filename)]
            if len(matches) != 1 or not 0 < matches[0].file_size <= limit:
                raise ValueError('Missing, ambiguous or oversized fixture metadata')
            return matches[0].filename, archive.read(matches[0])
        path, info = member(r'Payload/[^/]+\.app/Info\.plist', 1024 * 1024)
        bundle = plistlib.loads(info)['CFBundleIdentifier']
        if not isinstance(bundle, str) or row.get('bundle_id') != bundle:
            raise ValueError('Installed bundle differs from exported IPA')
        _, cms = member(re.escape(path.rsplit('/', 1)[0] + '/embedded.mobileprovision'), 2 * 1024 * 1024)
    if hashlib.sha256(cms).hexdigest() != row['profile_sha256']:
        raise ValueError('Installed profile differs from exported IPA')
    profile = plistlib.loads(decode(cms))
    team, = profile['TeamIdentifier']
    return dict(bundle_id=bundle, team_id=team, profile_expires_utc=profile['ExpirationDate'].strftime('%Y-%m-%dT%H:%M:%SZ'),
                marker_sha256=row['marker_sha256'])


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('observation', type=Path)
    p.add_argument('signed_ipa', type=Path)
    args = p.parse_args()
    try:
        result = convert(json.loads(args.observation.read_text()), args.signed_ipa,
                         lambda cms: subprocess.run(['/usr/bin/security', 'cms', '-D'], input=cms,
                                                    stdout=subprocess.PIPE, check=True).stdout)
        print(json.dumps(result, indent=2))
    except (ValueError, OSError, KeyError, TypeError, AttributeError, zipfile.BadZipFile, plistlib.InvalidFileException, subprocess.SubprocessError) as exc:
        sys.exit(f'Observation not accepted: {exc}')
