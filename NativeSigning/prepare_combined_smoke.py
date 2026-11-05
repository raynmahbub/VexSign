#!/usr/bin/env python3
"""Stage the app's constrained dependency graph with the privacy-patched native SDK.

No app/project/pin writes, credential use or native compilation. Network source
preparation is explicit. SwiftPM/Xcode resolution and device build are separate.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
spec = importlib.util.spec_from_file_location('combined_base_preparation', HERE / 'prepare_smoke.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
APP_PINS = ROOT / 'VexSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
SHARED = {'swift-crypto', 'swift-asn1', 'openssl'}
PRODUCTS = {
    'vapor': ['Vapor'], 'swift-nio-ssl': ['NIOSSL'], 'nuke': ['NukeUI'],
    'zip': ['Zip'], 'swcompression': ['SWCompression'], 'zipfoundation': ['ZIPFoundation'],
    'NimbleKit': ['NimbleExtensions', 'NimbleJSON', 'NimbleViews'],
    'AltSourceKit': ['AltSourceKit'], 'IDeviceKit': ['IDevice', 'IDeviceSwift']
}


def required_pins(app, candidate):
    pins = {}
    for pin in app['pins']:
        name = base.identity(pin['location'])
        if name != pin['identity'] or name in pins or not re.fullmatch(r'https://github\.com/[\w.-]+/[\w.-]+(?:\.git)?', pin['location']):
            raise ValueError('Unreviewed app package identity/URL')
        state = pin['state']
        if set(state) != {'version', 'revision'} or not re.fullmatch(r'\d+\.\d+\.\d+', state['version']) or not re.fullmatch(r'[0-9a-f]{40}', state['revision']):
            raise ValueError('Expected versioned immutable app package')
        pins[name] = dict(state)
    for name in ['vapor', 'swift-crypto', 'swift-asn1']:
        if name not in pins:
            raise ValueError('Missing shared app dependency: ' + name)
        pins[name] = candidate['required_pins'][name]
    return pins


def shared_remotes(text, app, expected):
    """Remove local shared-library overrides so the REAL remote ranges resolve.

    All app/Vapor transitive manifests stay untouched. SDK library-only/privacy
    overlays remain, but shared SDK requirements become reviewed remote exacts.
    """
    by_name = {p['identity']: p for p in app['pins']}
    pattern = r'\.package\(name: "([^"]+)", path: "\.\./(swift-crypto|swift-asn1|openssl)"\)'
    def replace(match):
        alias, name = match.groups()
        return '.package(name: "%s", url: "%s", exact: "%s")' % (alias, by_name[name]['location'], expected[name]['version'])
    result = re.sub(pattern, replace, text)
    if re.search(r'path:\s*"\.\./(?:swift-crypto|swift-asn1|openssl)"', result):
        raise ValueError('Unrecognized shared dependency declaration')
    return result


def manifest(app, expected):
    text = (HERE / 'Smoke/Package.swift.template').read_text().replace('// swift-tools-version: 6.0', '// swift-tools-version: 6.2')
    declarations = []
    for pin in app['pins']:
        name = pin['identity']
        declarations.append('.package(name: "%s", url: "%s", exact: "%s")' % (name, pin['location'], expected[name]['version']))
    declarations += ['.package(name: "%s", path: "Dependencies/%s")' % (name, folder) for name, folder in
                     [('NimbleKit', 'nimblekit'), ('AltSourceKit', 'altsourcekit'), ('IDeviceKit', 'idevicekit')]]
    needle = '.package(name: "Zsign", path: "Dependencies/zsign-package")'
    if text.count(needle) != 1:
        raise ValueError('Native package template changed')
    text = text.replace(needle, needle + ',\n        ' + ',\n        '.join(declarations))
    products = ['.product(name: "%s", package: "%s")' % (product, package) for package, names in PRODUCTS.items() for product in names]
    needle = '.product(name: "ZsignSwift", package: "Zsign")'
    if text.count(needle) != 1:
        raise ValueError('Native target template changed')
    return text.replace(needle, needle + ',\n        ' + ',\n        '.join(products))


def snapshot_package(source, destination):
    """Only declared local package inputs, never caches, credentials or .git."""
    for path in [source / 'Package.swift', source / 'Sources']:
        if path.is_symlink() or not path.exists():
            raise ValueError('Missing/unreviewed local package input: ' + str(path))
        if path.is_dir():
            if any(p.is_symlink() for p in path.rglob('*')):
                raise ValueError('Local package symlink requires review')
            shutil.copytree(path, destination / path.name)
        else:
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination / path.name)
    for path in source.glob('LICENSE*'):
        if path.is_symlink() or not path.is_file():
            raise ValueError('Local license input requires review')
        shutil.copy2(path, destination / path.name)


def prepare(work, lock, candidate, combined):
    raw = APP_PINS.read_bytes()
    if base.digest(raw) != candidate['app_baseline_sha256']:
        raise ValueError('App baseline changed; review before preparing')
    base.check_app_baseline(lock)
    base.check_codec_baseline(lock)
    vendored = json.loads((ROOT / 'Vendor/manifest.json').read_text())
    entry = next((item for item in vendored['packages'] if item['name'] == 'IDeviceKitten'), None)
    if entry is None or entry['commit'] != combined['idevicekit']['commit']:
        raise ValueError('Vendored IDeviceKitten pin changed; review before preparing')
    if base.digest((ROOT / 'Vendor/IDeviceKitten/Package.swift').read_bytes()) != combined['idevicekit']['manifest_sha256']:
        raise ValueError('Vendored IDeviceKit manifest changed; review before preparing')
    app = json.loads(raw)
    expected = required_pins(app, candidate)
    root_manifest = manifest(app, expected)
    base.prepare(work, lock)  # fresh directory; source hashes/privacy overlays checked
    overlays = {}
    for folder in ['sidesign', *(name for name in lock['packages'] if name not in SHARED)]:
        path = work / 'Dependencies' / folder / 'Package.swift'
        original = path.read_text()
        updated = shared_remotes(original, app, expected)
        if updated != original:
            path.write_text(updated)
            overlays[folder] = {'before_sha256': base.digest(original.encode()), 'combined_sha256': base.digest(updated.encode())}
    for name, folder in [('NimbleKit', 'nimblekit'), ('AltSourceKit', 'altsourcekit')]:
        snapshot_package(ROOT / name, work / 'Dependencies' / folder)
    idevice = work / 'Dependencies/idevicekit'
    base.checkout(combined['idevicekit'], idevice)
    if sorted(p.name for p in idevice.glob('Package*.swift')) != ['Package.swift'] or base.digest((idevice / 'Package.swift').read_bytes()) != combined['idevicekit']['manifest_sha256']:
        raise ValueError('IDeviceKit manifest changed')
    (work / 'Package.swift').write_text(root_manifest)
    shutil.copy2(HERE / 'Smoke/AppDependencyImports.swift', work / 'Sources/NativeSigningLinkSmoke/AppDependencyImports.swift')
    shutil.copy2(ROOT / 'VexSign/Backend/Server/ServerApplicationFactory.swift', work / 'Sources/NativeSigningLinkSmoke/ServerApplicationFactory.swift')
    # Hash every active SDK/local-package file, not only the logging patch sites.
    # Unused local Crypto/ASN1/OpenSSL copies remain from base preparation but
    # are NOT referenced by any manifest; the shared identity is remote only.
    hashes = source_hashes(work)
    (work / 'combined-provenance.json').write_text(json.dumps({
        'required_pins': expected, 'app_baseline_sha256': base.digest(raw),
        'candidate': candidate, 'combined_inputs': combined,
        'shared_remote_overlays': overlays, 'source_sha256': hashes,
        'scope': 'Constrained app-package + SDK candidate; not app source compilation or successful resolution'
    }, indent=2) + '\n')
    print('Combined candidate staged. No SwiftPM resolution, native build or app pin edits performed.')


def source_hashes(work):
    hashes = {}
    roots = [work / 'Sources', work / 'Tests']
    dependencies = work / 'Dependencies'
    if dependencies.exists():
        roots += [p for p in dependencies.iterdir() if p.is_dir() and p.name not in SHARED]
    for source in roots:
        for directory, folders, files in os.walk(source, followlinks=False):
            folders[:] = [name for name in folders if name != '.git']
            for name in folders + files:
                if (Path(directory) / name).is_symlink():
                    raise ValueError('Prepared source symlink requires review')
            for name in files:
                path = Path(directory) / name
                hashes[str(path.relative_to(work))] = base.digest(path.read_bytes())
    for name in ['Package.swift', 'provenance.json']:
        hashes[name] = base.digest((work / name).read_bytes())
    return hashes


def verify_remote_sources(work, checkouts, provenance):
    def checkout(name):
        matches = [p for p in checkouts.iterdir() if p.is_dir() and base.identity(p.name) == name]
        if len(matches) != 1:
            raise ValueError('Missing/ambiguous remote checkout: ' + name)
        return matches[0]
    source = checkout('vapor')
    review = provenance['candidate']['vapor']
    if sorted(p.name for p in source.glob('Package*.swift')) != review['manifests']:
        raise ValueError('Unreviewed Vapor compiler-specific manifest')
    for relative, expected in review['reviewed_files'].items():
        if base.digest((source / relative).read_bytes()) != expected:
            raise ValueError('Reviewed Vapor source drift: ' + relative)
    lock = json.loads((work / 'provenance.json').read_text())['inputs']
    for name in SHARED:
        if base.digest((checkout(name) / 'Package.swift').read_bytes()) != lock['packages'][name]['manifest_sha256']:
            raise ValueError('Shared remote manifest drift: ' + name)


def verify(work, resolved, checkouts=None):
    provenance = json.loads((work / 'combined-provenance.json').read_text())
    if base.digest(APP_PINS.read_bytes()) != provenance['app_baseline_sha256']:
        raise ValueError('App baseline drift')
    if source_hashes(work) != provenance['source_sha256']:
        raise ValueError('Prepared combined source drift (modified/added/deleted file)')
    rows = json.loads(resolved.read_text())['pins']
    pins = {p['identity']: p['state'] for p in rows}
    if len(rows) != len(pins):
        raise ValueError('Duplicate resolved package identity')
    if pins != provenance['required_pins']:
        raise ValueError('Combined resolution differs; review new/moved dependencies before building')
    verify_remote_sources(work, checkouts or work / '.build/checkouts', provenance)
    (work / 'combined-resolution-attestation.json').write_text(json.dumps({
        'resolved_sha256': base.digest(resolved.read_bytes()), 'pins': pins,
        'scope': 'Source/pin verification only, not a successful native build'
    }, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=ROOT / '.build/combined-signing-smoke')
    parser.add_argument('--checkouts', type=Path, help='Optional Xcode checkouts directory for verification')
    parser.add_argument('--verify-resolved', type=Path, help='Verify a real SwiftPM/Xcode Package.resolved before building')
    args = parser.parse_args()
    if args.verify_resolved:
        verify(args.work, args.verify_resolved, args.checkouts)
    else:
        prepare(args.work, json.loads((HERE / 'inputs.lock.json').read_text()),
                json.loads((HERE / 'ServerCompatibility/candidate-review.json').read_text()),
                json.loads((HERE / 'combined-inputs.json').read_text()))


if __name__ == '__main__':
    main()
