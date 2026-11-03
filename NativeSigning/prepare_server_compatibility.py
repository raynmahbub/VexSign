#!/usr/bin/env python3
"""Stage/verify the disposable Vapor/Crypto candidate; never edits the app graph."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
INPUTS = HERE / 'ServerCompatibility'
FACTORY = Path('VexSign/Backend/Server/ServerApplicationFactory.swift')
APP_PINS = ROOT / 'VexSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def check_baseline(review):
    if digest(APP_PINS.read_bytes()) != review['app_baseline_sha256']:
        raise ValueError('App pins changed; review the candidate against the new baseline')


def staging_files():
    return {
        INPUTS / 'Package.swift.template': 'Package.swift',
        ROOT / FACTORY: 'Sources/ServerDependencyCompatibility/ServerApplicationFactory.swift',
        INPUTS / 'ServerDependencyProbe.swift': 'Sources/ServerDependencyCompatibility/ServerDependencyProbe.swift',
        INPUTS / 'ServerApplicationFactoryTests.swift': 'Tests/ServerDependencyCompatibilityTests/ServerApplicationFactoryTests.swift',
        INPUTS / 'candidate-review.json': 'candidate-review.json',
    }


def prepare(work, review):
    check_baseline(review)
    work.mkdir(parents=True, exist_ok=False)
    files = staging_files()
    hashes = {}
    for source, relative in files.items():
        destination = work / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        hashes[relative] = digest(destination.read_bytes())
    (work / 'provenance.json').write_text(json.dumps({'review': review, 'first_party_sha256': hashes}, indent=2) + '\n')


def verify(work, review):
    """Run AFTER SwiftPM resolve and BEFORE build; fail on moved tags/source drift."""
    check_baseline(review)
    provenance = json.loads((work / 'provenance.json').read_text())
    if provenance['review'] != review:
        raise ValueError('Prepared candidate review changed; prepare a new directory')
    current = {relative: digest(source.read_bytes()) for source, relative in staging_files().items()}
    if provenance['first_party_sha256'] != current:
        raise ValueError('First-party inputs changed; prepare a new directory')
    for relative, expected in current.items():
        if digest((work / relative).read_bytes()) != expected:
            raise ValueError('Prepared first-party source changed: ' + relative)
    raw = (work / 'Package.resolved').read_bytes()
    pins = {p['identity']: p['state'] for p in json.loads(raw)['pins']}
    for name, expected in review['required_pins'].items():
        if pins.get(name) != expected:
            raise ValueError('Unexpected resolved candidate version/revision: ' + name)
    source = work / '.build/checkouts/vapor'
    if sorted(p.name for p in source.glob('Package*.swift')) != review['vapor']['manifests']:
        raise ValueError('Unreviewed Vapor compiler-specific manifest')
    for relative, expected in review['vapor']['reviewed_files'].items():
        if digest((source / relative).read_bytes()) != expected:
            raise ValueError('Resolved Vapor source differs from review: ' + relative)
    # Record the complete resolution, not just the five constrained packages.
    (work / 'resolution-attestation.json').write_text(json.dumps({
        'package_resolved_sha256': digest(raw), 'pins': pins,
        'scope': 'Candidate source verification only; not a native build or full app/SDK resolution'
    }, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=ROOT / '.build/server-dependency-compatibility')
    parser.add_argument('--verify-resolved', action='store_true')
    args = parser.parse_args()
    review = json.loads((INPUTS / 'candidate-review.json').read_text())
    if args.verify_resolved:
        verify(args.work, review)
        print('Candidate sources/resolution verified; native build/tests remain required.')
    else:
        prepare(args.work, review)
        print('Candidate staged without network requests, app pin changes, or native compilation.')


if __name__ == '__main__':
    main()
