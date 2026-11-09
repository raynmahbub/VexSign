#!/usr/bin/env python3
"""Deterministic, non-installable fixture corpus. Outputs belong outside Git.

The portable hash benchmark measures this host, NOT VexSign/iOS import performance.
No executable, private key, profile, copyrighted IPA, or device result is generated.
"""
import argparse
import hashlib
import json
import math
import plistlib
import statistics
import time
import zipfile
from pathlib import Path


def member(archive, name, data):
    info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_STORED
    info.external_attr = 0o100644 << 16
    archive.writestr(info, data)


def generate(root, payload_mib=16, small_files=2000, catalog_apps=10000):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=False)
    manifest = {'schema': 1, 'synthetic': True, 'installable': False, 'fixtures': []}
    for kind in ('large-payload', 'many-small-files', 'nested-bundles'):
        path = root / (kind + '.ipa')
        base = 'Payload/Fixture.app/'
        with zipfile.ZipFile(path, 'w', allowZip64=True) as archive:
            member(archive, base + 'Info.plist', plistlib.dumps({
                'CFBundleIdentifier': 'invalid.vexsign.fixture', 'CFBundleName': 'Fixture',
                'CFBundleExecutable': 'Fixture', 'CFBundleVersion': '1',
                'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '17.0'}))
            member(archive, base + 'Fixture', b'NOT AN EXECUTABLE: benchmark fixture only\n')
            if kind == 'large-payload':
                info = zipfile.ZipInfo(base + 'payload.bin', (2020, 1, 1, 0, 0, 0))
                with archive.open(info, 'w', force_zip64=True) as output:
                    block = bytes(range(256)) * 4096
                    for _ in range(payload_mib):
                        output.write(block)
            elif kind == 'many-small-files':
                for index in range(small_files):
                    member(archive, base + f'resources/{index:06}.bin', hashlib.sha256(str(index).encode()).digest() * 32)
            else:
                for index in range(12):
                    nested = base + f'PlugIns/Extension{index}.appex/'
                    member(archive, nested + 'Info.plist', plistlib.dumps({
                        'CFBundleIdentifier': f'invalid.vexsign.fixture.extension{index}',
                        'CFBundleExecutable': 'Fixture', 'MinimumOSVersion': '18.0'}))
                    member(archive, nested + 'Fixture', b'NOT AN EXECUTABLE\n')
        manifest['fixtures'].append({'file': path.name, 'bytes': path.stat().st_size,
                                     'sha256': digest(path)})
    catalog = [{'bundleIdentifier': f'invalid.fixture.app{i}', 'name': f'Fixture {i}',
                'version': '2.0', 'iconURL': 'https://example.invalid/icon.png',
                'downloadURL': f'https://example.invalid/{i}.ipa'} for i in range(catalog_apps)]
    (root / 'catalog.json').write_text(json.dumps({'name': 'Synthetic source', 'apps': catalog}))
    (root / 'library.json').write_text(json.dumps([
        {'identifier': f'invalid.fixture.app{i}', 'version': '1.0', 'uuid': f'fixture-{i}'}
        for i in range(min(catalog_apps, 1000))]))
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def benchmark(root, iterations=5):
    rows = []
    for path in sorted(Path(root).glob('*.ipa')):
        samples = []
        for _ in range(iterations):
            start = time.perf_counter()
            digest(path)
            samples.append(time.perf_counter() - start)
        rows.append({'file': path.name, 'bytes': path.stat().st_size, 'samples_seconds': samples,
                     'median_seconds': statistics.median(samples),
                     'p95_seconds': sorted(samples)[math.ceil(.95 * len(samples)) - 1],
                     'app_peak_memory_bytes': None, 'app_cancellation_latency_seconds': None})
    return {'schema': 1, 'scope': 'portable-host-sha256-only', 'ios_verified': False, 'results': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    gen = sub.add_parser('generate')
    gen.add_argument('directory', type=Path)
    gen.add_argument('--payload-mib', type=int, choices=range(1, 1025), default=16)
    gen.add_argument('--small-files', type=int, choices=range(1, 20001), default=2000)
    gen.add_argument('--catalog-apps', type=int, choices=range(1, 50001), default=10000)
    run = sub.add_parser('benchmark')
    run.add_argument('directory', type=Path)
    run.add_argument('--iterations', type=int, choices=range(2, 101), default=5)
    args = parser.parse_args()
    if args.action == 'generate':
        generate(args.directory, args.payload_mib, args.small_files, args.catalog_apps)
    else:
        print(json.dumps(benchmark(args.directory, args.iterations), indent=2))


if __name__ == '__main__':
    main()
