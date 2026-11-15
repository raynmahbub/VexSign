#!/usr/bin/env python3
"""Offline source/build boundary regressions, not native or phone acceptance."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('device_bridge_prepare', HERE / 'prepare.py')
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


class PreparationTests(unittest.TestCase):
    def test_source_pin_is_an_immutable_mit_archive_not_a_newer_unpatched_binary(self):
        record = PREPARE.read_lock()
        self.assertEqual(record['sourceCommit'], 'd32c8189c51c2789496b0768039419c3705498c3')
        self.assertIn(record['sourceCommit'], record['archiveURL'])
        self.assertEqual(record['license'], 'MIT')
        self.assertEqual(hashlib.sha256((HERE / record['licenseFile']).read_bytes()).hexdigest(), record['licenseSHA256'])
        self.assertIn('physical acceptance', record['acceptance'])
        for source in ('Cargo.lock', 'ffi/src/provider.rs', 'idevice/src/remote_pairing/mod.rs'):
            self.assertIn(source, record['reviewedSourceSHA256'])

    def test_modified_upstream_inputs_are_refused_before_patching(self):
        with self.assertRaisesRegex(ValueError, 'source changed'):
            PREPARE.patch_sources({'ffi/src/lib.rs': b'unreviewed'}, PREPARE.read_lock())

    def test_missing_or_ambiguous_patch_context_is_refused(self):
        for source in ('no matching content', 'old bytes old bytes'):
            with self.assertRaises(ValueError):
                PREPARE.replace_once(source, 'old bytes', 'new bytes')
        self.assertEqual(PREPARE.replace_once('one old bytes', 'old bytes', 'new bytes'), 'one new bytes')

    def test_archive_checksum_is_required_even_for_a_valid_zip(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as archive:
            archive.writestr('arbitrary/source.rs', 'unreviewed')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            PREPARE.archive_files(output.getvalue(), PREPARE.read_lock())

    def test_archive_links_cannot_escape_or_be_silently_flattened(self):
        for filename in ('../outside', '/outside', 'wrong-root/file'):
            output = io.BytesIO()
            with zipfile.ZipFile(output, 'w') as archive:
                archive.writestr(filename, 'unreviewed')
            record = dict(PREPARE.read_lock(), archiveSHA256=hashlib.sha256(output.getvalue()).hexdigest())
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                PREPARE.archive_files(output.getvalue(), record)

    def test_existing_xcframework_must_match_current_sources_and_every_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work, product = root / '.build/work', root / '.build/product'
            with patch.multiple(PREPARE, ROOT=root, WORK=work, PRODUCT=product):
                self.assertFalse(PREPARE.verify_product())
                framework = product / 'IDevice.xcframework'
                framework.mkdir()
                (framework / 'Info.plist').write_bytes(b'fixture')
                record = {'inputFingerprint': PREPARE.fingerprint(),
                          'artifactSHA256': {'Info.plist': hashlib.sha256(b'fixture').hexdigest()}}
                (product / 'provenance.json').write_text(json.dumps(record))
                self.assertTrue(PREPARE.verify_product())
                (framework / 'extra.a').write_bytes(b'unreviewed')
                self.assertFalse(PREPARE.verify_product())
                (framework / 'extra.a').unlink()
                (framework / 'Info.plist').write_bytes(b'changed')
                self.assertFalse(PREPARE.verify_product())

    def test_product_under_symlink_is_refused_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / 'outside'
            outside.mkdir()
            linked = root / 'linked'
            linked.symlink_to(outside, target_is_directory=True)
            with patch.multiple(PREPARE, ROOT=root, WORK=root / 'work', PRODUCT=linked / 'product'):
                with self.assertRaisesRegex(ValueError, 'symlinks'):
                    PREPARE.safe_work()
                self.assertEqual(list(outside.iterdir()), [])


class NativeBoundarySourceTests(unittest.TestCase):
    def setUp(self):
        self.source = (HERE / 'Native/vexsign_device.rs').read_text()

    def test_verify_only_entrypoint_cannot_start_a_new_pairing_or_supply_a_pin(self):
        function = self.source.split('fn vexsign_tunnel_rppairing_verified(', 1)[1].split('/// One ephemeral', 1)[0]
        self.assertIn('client.attempt_pair_verify().await?', function)
        self.assertIn('client.validate_pairing(&mut record).await?', function)
        for forbidden in ('.connect(&mut record', '.pair(', 'pin_callback', '000000', 'tunnel_create_rppairing('):
            self.assertNotIn(forbidden, function)
        self.assertIn('IpAddr::V4(ip)) if ip.is_private() || ip.is_link_local()', function)

    def test_host_pinless_mode_is_not_an_abi_option(self):
        function = self.source.split('fn vexsign_pairable_host_prepare(', 1)[1].split('fn enrolled_record(', 1)[0]
        self.assertIn('info.allows_pinless_pairing = false', function)
        self.assertIn('record.identifier = uuid::Uuid::new_v4()', function)
        self.assertNotIn('allows_pinless_pairing: bool', function)
        self.assertIn('pin_callback.is_none()', self.source)

    def test_host_identity_and_irks_remain_in_one_exact_protected_record(self):
        self.assertIn('"host_alt_irk"', self.source)
        self.assertIn('"remotepairing_udid"', self.source)
        self.assertNotIn('write_to_file(', self.source)
        self.assertNotIn('std::fs::write', self.source)
        self.assertIn('record.e_private_key.verifying_key() != record.e_public_key', self.source)

    def test_cancellation_deadline_and_allocator_ownership_are_explicit(self):
        for required in ('tokio::select!', 'biased;', 'tokio::time::timeout', 'cancel.acquire()',
                         'libc::dup(fd)', 'TcpStream::from_raw_fd(duplicate)',
                         'bytes.into_boxed_slice()', 'slice_from_raw_parts_mut(data, length)'):
            self.assertIn(required, self.source)
        self.assertNotIn('std::mem::forget', self.source)
        for function in ('vexsign_tunnel_rppairing_verified', 'vexsign_pairable_host_accept_fd'):
            body = self.source.split('fn ' + function + '(', 1)[1]
            self.assertIn('bounded(cancel, milliseconds', body)

    def test_native_protocol_tracing_is_compiled_out_in_both_crates(self):
        source = (HERE / 'prepare.py').read_text()
        self.assertIn("for name in ('ffi/Cargo.toml', 'idevice/Cargo.toml')", source)
        self.assertIn('"max_level_off", "release_max_level_off"', source)
        self.assertNotIn('debug!(', self.source)
        self.assertNotIn('println!', self.source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
