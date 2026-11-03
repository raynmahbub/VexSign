import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location('prepare_combined_smoke', HERE / 'prepare_combined_smoke.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CombinedSmokeTests(unittest.TestCase):
    def setUp(self):
        self.app = json.loads(module.APP_PINS.read_text())
        self.candidate = json.loads((HERE / 'ServerCompatibility/candidate-review.json').read_text())
        self.expected = module.required_pins(self.app, self.candidate)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def test_only_three_proposed_versions_change_from_app_baseline(self):
        old = {p['identity']: p['state'] for p in self.app['pins']}
        self.assertEqual({name for name in old if old[name] != self.expected[name]}, {'vapor', 'swift-crypto', 'swift-asn1'})
        text = module.manifest(self.app, self.expected)
        for pin in self.app['pins']:
            self.assertIn('name: "%s", url: "%s", exact: "%s"' % (pin['identity'], pin['location'], self.expected[pin['identity']]['version']), text)
        for package, products in module.PRODUCTS.items():
            for product in products:
                self.assertIn('.product(name: "%s", package: "%s")' % (product, package), text)
        self.assertIn('NativeSigningCodecTests', text)

    def test_shared_sdk_dependencies_use_same_remote_identities(self):
        for name in module.SHARED:
            text = '.package(name: "%s", path: "../%s")' % (name, name)
            output = module.shared_remotes(text, self.app, self.expected)
            self.assertNotIn('path:', output)
            self.assertIn('exact: "%s"' % self.expected[name]['version'], output)
        with self.assertRaisesRegex(ValueError, 'Unrecognized'):
            module.shared_remotes('.package(path: "../swift-crypto")', self.app, self.expected)

    def test_unknown_or_duplicate_app_identity_fails_closed(self):
        app = copy.deepcopy(self.app)
        app['pins'].append(app['pins'][0])
        with self.assertRaises(ValueError):
            module.required_pins(app, self.candidate)
        app = copy.deepcopy(self.app)
        app['pins'][0]['location'] = 'https://unreviewed.invalid/APIKit'
        with self.assertRaises(ValueError):
            module.required_pins(app, self.candidate)

    def test_snapshot_copies_declared_inputs_not_caches_or_git(self):
        source = self.work / 'original'
        (source / 'Sources').mkdir(parents=True)
        (source / 'Package.swift').write_text('manifest')
        (source / 'Sources/Example.swift').write_text('source')
        (source / '.git').mkdir()
        (source / '.git/config').write_text('not for copying')
        (source / '.build').mkdir()
        target = self.work / 'snapshot'
        module.snapshot_package(source, target)
        self.assertEqual((target / 'Sources/Example.swift').read_text(), 'source')
        self.assertFalse((target / '.git').exists())
        self.assertFalse((target / '.build').exists())

    def test_snapshot_rejects_source_symlinks(self):
        source = self.work / 'original'
        (source / 'Sources').mkdir(parents=True)
        (source / 'Package.swift').write_text('manifest')
        (source / 'Sources/linked').symlink_to(source / 'Package.swift')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            module.snapshot_package(source, self.work / 'snapshot')

    def verification_fixture(self):
        (self.work / 'Sources').mkdir()
        (self.work / 'Sources/Example.swift').write_text('source')
        (self.work / 'Package.swift').write_text('manifest')
        (self.work / 'provenance.json').write_text('{}')
        proof = {'required_pins': self.expected, 'app_baseline_sha256': module.base.digest(module.APP_PINS.read_bytes()), 'source_sha256': module.source_hashes(self.work)}
        (self.work / 'combined-provenance.json').write_text(json.dumps(proof))
        resolved = self.work / 'Package.resolved'
        self.write_pins(resolved, self.expected)
        return resolved

    def write_pins(self, path, pins):
        path.write_text(json.dumps({'pins': [{'identity': key, 'state': state} for key, state in pins.items()]}))

    def test_attestation_requires_source_pin_and_remote_verification(self):
        resolved = self.verification_fixture()
        with patch.object(module, 'verify_remote_sources') as check:
            module.verify(self.work, resolved)
            check.assert_called_once()
        self.assertTrue((self.work / 'combined-resolution-attestation.json').exists())
        pins = copy.deepcopy(self.expected)
        pins['vapor']['revision'] = '0' * 40
        self.write_pins(resolved, pins)
        with self.assertRaisesRegex(ValueError, 'resolution differs'):
            module.verify(self.work, resolved)

    def test_duplicate_resolved_identity_is_rejected(self):
        resolved = self.verification_fixture()
        value = json.loads(resolved.read_text())
        value['pins'].append(value['pins'][0])
        resolved.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'Duplicate resolved'):
            module.verify(self.work, resolved)

    def test_injected_unhashed_source_is_rejected_before_resolution(self):
        resolved = self.verification_fixture()
        (self.work / 'Sources/Injected.swift').write_text('unexpected')
        with self.assertRaisesRegex(ValueError, 'source drift'):
            module.verify(self.work, resolved)

    def test_remote_checkout_verification_rejects_missing_packages(self):
        self.verification_fixture()
        checkout = self.work / 'checkouts'
        checkout.mkdir()
        with self.assertRaisesRegex(ValueError, 'Missing/ambiguous remote checkout: vapor'):
            module.verify_remote_sources(self.work, checkout, {'candidate': self.candidate})


if __name__ == '__main__':
    unittest.main()
