#!/usr/bin/env python3
"""Prime SwiftPM's binary archive cache using retrying, checksum-verified curl.

Work around NSURLSession release-download failures on companion builds. No
manifests, package pins, extracted frameworks or build checks are modified.
SwiftPM still verifies each cached archive against its resolved manifest.
"""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urldefrag

# Release archive checksums from the corresponding package manifests. Deliberate
# pinned inputs, never hashes obtained from an untrusted download response.
OPENSSL = 'https://github.com/krzyzanowskim/OpenSSL/releases/download/3.6.2000/OpenSSL.xcframework.zip'
ARTIFACTS = (
    (OPENSSL + '#CodeSignKit', '37846a8bd302cb2443eff47f1045ab844d0cd40bf82cc6159cfad9aa5c3eff9e'),
    (OPENSSL + '#GSACryptoKit', '37846a8bd302cb2443eff47f1045ab844d0cd40bf82cc6159cfad9aa5c3eff9e'),
    ('https://github.com/mahee96/unicorn/releases/download/2.1.4-xcf-a53ddc9/Unicorn.xcframework.zip#AnisetteKit',
     '52e4ac9e2d704c4941adc2c381df8706aabf673dc843611a90b33ad349d562db'),
    ('https://github.com/jkcoxson/idevice/releases/download/v0.1.57/IDevice.xcframework.zip',
     '40cd5c769b60d1879a96c9caa27666037f9d5321844addec40ae99727b142d10'),
    ('https://github.com/mono0926/LicensePlist/releases/download/3.27.1/LicensePlistBinary-macos.artifactbundle.zip',
     '24e066b23da58275a89a83cae05bf40cad8a48faacf10facbfa5c350efe02608'),
)


def cache_key(url):
    # SwiftPM spm_mangledToC99ExtendedIdentifier, restricted to these ASCII URLs.
    return re.sub(r'[^a-zA-Z0-9_]', '_', url)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def prefetch(cache, artifacts=ARTIFACTS, download=None):
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    if download is None:
        def download(url, target):
            result = subprocess.run([
                'curl', '--fail', '--location', '--silent', '--show-error',
                '--proto', '=https', '--proto-redir', '=https',
                '--retry', '4', '--retry-all-errors', '--connect-timeout', '30',
                '--max-time', '300', '--output', str(target), url,
            ], capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(
                    f'Failed to download {url} (curl exit {result.returncode}): '
                    f'{result.stderr.strip() or "no curl diagnostic"}'
                )
    with tempfile.TemporaryDirectory(prefix='.prefetch-', dir=cache) as work:
        downloaded = {}
        for url, expected in artifacts:
            destination = cache / cache_key(url)
            if destination.is_file() and digest(destination) == expected:
                print('Verified cached archive:', url, flush=True)
                continue
            remote, _ = urldefrag(url)
            source = downloaded.get((remote, expected))
            if source is None:
                source = Path(work) / str(len(downloaded))
                download(remote, source)
                if digest(source) != expected:
                    raise ValueError('SHA-256 mismatch for ' + remote)
                downloaded[remote, expected] = source
            # Publish complete verified bytes only; a failed download never
            # overwrites a previously cached archive. No extraction/zip-slip here.
            staging = Path(work) / (destination.name + '.verified')
            shutil.copyfile(source, staging)
            staging.replace(destination)
            print('Verified release archive:', url, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', required=True, type=Path)
    args = parser.parse_args()
    try:
        prefetch(args.cache)
    except Exception as error:
        # Actions annotations remain visible even when the full job log cannot
        # be downloaded. Escape workflow-command delimiters, but still fail.
        message = str(error).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print(f'::error title=Binary archive prefetch failed::{message}', flush=True)
        raise


if __name__ == '__main__':
    main()
