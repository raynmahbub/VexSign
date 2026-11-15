#!/usr/bin/env python3
"""Offline preparation/security-wiring checks, NOT Swift/runtime or device tests."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
SPEC = importlib.util.spec_from_file_location("prepare_device_foundation", HERE / "prepare_device_foundation.py")
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)
APP = ROOT / "VexSign/App/iOS"
VENDOR = ROOT / PREPARE.VENDOR


class DeviceFoundationPreparationTests(unittest.TestCase):
    def test_host_package_copies_production_and_tests_without_source_rewrites(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary).resolve() / "device-foundation"
            hashes = PREPARE.prepare(output)
            self.assertEqual(len(hashes), len(PREPARE.PRODUCTION) + len(PREPARE.FIXTURES) + 1)
            for name, relative in PREPARE.PRODUCTION.items():
                source = ROOT / relative
                self.assertEqual((output / "Sources/DeviceFoundation" / name).read_bytes(), source.read_bytes())
                self.assertEqual(hashes[source.relative_to(ROOT).as_posix()], hashlib.sha256(source.read_bytes()).hexdigest())
            for name in PREPARE.FIXTURES:
                self.assertEqual((output / "Tests/DeviceFoundationTests" / name).read_bytes(),
                                 (ROOT / PREPARE.TESTS / name).read_bytes())
            self.assertEqual(json.loads((output / "source-hashes.json").read_text())["sourceSHA256"], hashes)
            self.assertEqual(PREPARE.prepare(output), hashes)

    def test_host_graph_has_no_network_binary_device_or_account_dependency(self):
        manifest = PREPARE.MANIFEST
        self.assertIn('.macOS(.v13)', manifest)
        for forbidden in ('.package(', '.binaryTarget(', 'https://', 'IDeviceSwift', 'NativeSigning'):
            self.assertNotIn(forbidden, manifest)
        self.assertIn('DeviceOperationExecutor.swift', PREPARE.PRODUCTION)
        self.assertIn('PairingFileStorageTests.swift', PREPARE.FIXTURES)
        self.assertNotIn('DeviceServiceSession.swift', PREPARE.PRODUCTION)

    def test_preparation_rejects_symlinked_or_unexpected_sources_instead_of_erasing_them(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            output = root / "device-foundation"
            PREPARE.prepare(output)
            extra = output / "Sources/DeviceFoundation/Unexpected.swift"
            extra.write_text("// must survive refusal")
            with self.assertRaises(ValueError):
                PREPARE.prepare(output)
            self.assertEqual(extra.read_text(), "// must survive refusal")
            link = root / "elsewhere" / "device-foundation"
            link.parent.mkdir()
            link.symlink_to(output, target_is_directory=True)
            with self.assertRaises(ValueError):
                PREPARE.prepare(link)
            self.assertTrue(extra.exists())

    def test_preparation_refuses_source_symlinks_before_writing_any_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            sources = list(PREPARE.PRODUCTION.values()) + [f"{PREPARE.TESTS}/{name}" for name in PREPARE.FIXTURES]
            for relative in sources:
                source = ROOT / relative
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(source.read_bytes())
            license_path = Path('VexSign/Packages/Vendor/IDeviceKitten/LICENSE')
            (root / license_path).write_bytes((ROOT / license_path).read_bytes())
            source = root / next(iter(PREPARE.PRODUCTION.values()))
            source.unlink()
            source.symlink_to(root / license_path)
            output = root / 'device-foundation'
            with patch.object(PREPARE, 'ROOT', root), self.assertRaises(ValueError):
                PREPARE.prepare(output)
            self.assertFalse(output.exists())

    def test_vendor_patch_manifest_hashes_match_all_reviewed_local_sources(self):
        manifest = json.loads((ROOT / 'VexSign/Packages/Vendor/manifest.json').read_text())
        package = next(item for item in manifest['packages'] if item['name'] == 'IDeviceKitten')
        base = ROOT / package['path']
        paths = set()
        self.assertEqual(len(package['localPatches']), 6)
        self.assertEqual(len(package['localAdditions']), 9)
        for entry in package['localPatches'] + package['localAdditions']:
            relative = Path(entry['path'])
            self.assertFalse(relative.is_absolute())
            self.assertNotIn('..', relative.parts)
            self.assertTrue(entry['path'].startswith('Sources/IDeviceSwift/'))
            self.assertNotIn(entry['path'], paths)
            paths.add(entry['path'])
            self.assertEqual(hashlib.sha256((base / relative).read_bytes()).hexdigest(), entry['patchedSHA256'])
        for entry in package['localPatches']:
            self.assertRegex(entry['baseSHA256'], r'^[0-9a-f]{64}$')
        for entry in package['localAdditions']:
            self.assertTrue(entry['upstreamPathAbsent'])
            self.assertEqual(entry['license'], 'MIT')
        self.assertTrue((base / package['localPatchReview']).is_file())
        self.assertEqual(hashlib.sha256((base / 'LICENSE').read_bytes()).hexdigest(), package['licenseSHA256'])

    def test_dependency_pins_stay_independent_from_unaccepted_binary_abi_or_license_claims(self):
        manifest = json.loads((ROOT / 'VexSign/Packages/Vendor/manifest.json').read_text())
        package = next(item for item in manifest['packages'] if item['name'] == 'IDeviceKitten')
        self.assertEqual(package['commit'], '837cf1e14d4875771dd5ee1b754a4c86215c5db3')
        self.assertEqual(package['license'], 'MIT')
        dependency, = package['binaryDependencies']
        self.assertEqual(dependency['version'], '0.1.57')
        self.assertEqual(dependency['sourceCommit'], '99ea020acabd0579375a09fd690261ea6ca37f68')
        self.assertIn('not accepted', dependency['reviewStatus'])
        binary_manifest = ROOT / package['path'] / 'Package.swift'
        self.assertIn(dependency['url'], binary_manifest.read_text())
        self.assertIn(dependency['swiftPMChecksum'], binary_manifest.read_text())
        self.assertEqual(hashlib.sha256(binary_manifest.read_bytes()).hexdigest(),
                         '7213f941601c9e4057eff12bc61e35e64bb2da0ffa9da452e587be80adc5c8b2')


class DeviceFoundationSecurityWiringTests(unittest.TestCase):
    def text(self, relative):
        return (ROOT / relative).read_text()

    def test_paired_mutations_remain_blocked_before_native_side_effects(self):
        proxy = self.text("VexSign/Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift")
        inventory = self.text("VexSign/Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationAppProxy.swift")
        self.assertRegex(inventory, r'public static var hasAcceptedInventoryBridge: Bool \{\s*false\s*\}')
        self.assertLess(proxy.index('guard InstallationAppProxy.hasAcceptedInventoryBridge'), proxy.index('withDeviceSession'))
        self.assertNotIn('self.status(.completed(.success', proxy)
        self.assertNotIn('NSSelectorFromString', proxy)
        self.assertNotIn('free(UnsafeMutableRawPointer', inventory)

    def test_updater_has_no_signing_key_upload_private_probe_suspend_or_silent_switch(self):
        updater = (APP / "Infrastructure/Updates/SelfUpdateManager.swift").read_text()
        for forbidden in ('requestServerSign', '/vexsign/sign', 'p12password', '.signingPassword',
                          '.upload(', 'InstalledAppProbe()', 'installProgress(for:', 'suspend:',
                          'adopt(alternative', 'phase = .done'):
            self.assertNotIn(forbidden, updater, forbidden)
        run = updater.split('func performUpdate(to release:', 1)[1]
        self.assertIn('phase = .failed(blocker.message)', run)
        self.assertNotIn('URLSession', run)
        self.assertNotIn('resolvedCertificate()', run)
        self.assertIn('alternative: nil', updater)

    def test_no_automatic_vpn_activation_url_is_present_in_app_sources(self):
        offenders = []
        for path in APP.rglob('*.swift'):
            source = path.read_text()
            if 'localdevvpn://enable' in source.lower() or 'localdevvpn://connect' in source.lower():
                offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual(offenders, [])

    def test_installers_have_no_silent_paired_fallback_or_private_progress_authority(self):
        installer = (APP / 'Infrastructure/Devices/Installation/AppInstaller.swift').read_text()
        for forbidden in ('_attemptIdeviceFallback', '_didAttemptIdeviceFallback', 'installProgress(for:', 'InstalledAppProbe()'):
            self.assertNotIn(forbidden, installer)
        self.assertEqual(installer.count('InstallationProxy(viewModel:'), 1)
        self.assertIn('probe: InstalledAppProbing = UnavailableInstallationProbe()', installer)
        self.assertIn('paired-installed-version-not-verified', installer)
        for path in ('Infrastructure/Devices/Installation/DeviceAppRemoval.swift',
                     'Infrastructure/Persistence/Repositories/LibraryStatusStore.swift'):
            self.assertNotIn('InstalledAppProbe()', (APP / path).read_text())

    def test_storage_path_is_pure_and_recovery_is_inside_both_executor_entrypoints(self):
        storage = (VENDOR / 'PairingFileStorage.swift').read_text()
        self.assertIn('public static func path() -> String { currentURL.path }', storage)
        heartbeat = (VENDOR / 'Heartbeat.swift').read_text()
        self.assertEqual(heartbeat.count('try PairingFileStorage.prepare()'), 2)
        for operation in ('try await executor.run {', 'try await executor.run(waiterTimeout: waiterTimeout) {'):
            body = heartbeat.split(operation, 1)[1].split('\n    }', 1)[0]
            self.assertLess(body.index('PairingFileStorage.prepare()'), body.index('return try work('))
        launch = (APP / 'App/Lifecycle/AppLifecycleCoordinator.swift').read_text()
        self.assertIn('try await PairingBridge.recoverLocalStorage()', launch)
        self.assertNotIn('queryDevice(', launch)

    def test_timeout_or_cancellation_does_not_retire_the_native_admission_slot(self):
        executor = (VENDOR / 'DeviceOperationExecutor.swift').read_text()
        self.assertEqual(executor.count('self.retire(token)'), 1)
        worker = executor.split('queue.async {', 1)[1].split('}, onCancel:', 1)[0]
        self.assertLess(worker.index('try work(token)'), worker.index('self.retire(token)'))
        self.assertNotIn('retire(', executor.split('}, onCancel:', 1)[1].split('private final class', 1)[0])
        self.assertNotIn('assumingMemoryBound', executor)

    def test_storage_creation_protection_and_export_cleanup_remain_explicit(self):
        storage = (VENDOR / 'PairingFileStorage.swift').read_text()
        for required in ('O_NOFOLLOW', 'O_NONBLOCK', 'fstat(', 'sameFile(before, after)',
                         'beforeCommit()', 'Darwin.link(', 'Darwin.rename(', 'isExcludedFromBackup = true',
                         'FileProtectionType.complete', '.completeFileProtection', 'inspected > 128'):
            self.assertIn(required, storage)
        # Host tests never silently relax the physical iOS protection gate.
        self.assertIn('#if os(iOS) && !targetEnvironment(simulator)', storage)
        self.assertNotIn('isDataProtectionUnsupported', storage)
        picker = (APP / 'Platform/iOS/DocumentPicker/DocumentPicker.swift').read_text()
        self.assertIn('onFinish?(); return', picker)
        self.assertIn('presenter.presentedViewController == nil', picker)
        self.assertIn('!presenter.isBeingPresented', picker)
        self.assertIn('!presenter.isBeingDismissed', picker)
        self.assertIn('presenter.transitionCoordinator == nil', picker)
        self.assertIn('DispatchQueue.main.async { [weak picker, weak delegate]', picker)
        self.assertIn('delegate.presentationFailed()', picker)
        self.assertIn('picker.presentationController?.delegate = delegate\n        presenter.present', picker)
        self.assertIn('presentationControllerDidDismiss', picker)
        self.assertIn('guard !_finished else { return }', picker)

    def test_missing_version_and_legacy_history_cannot_create_installed_evidence(self):
        probe = (APP / 'Infrastructure/Devices/Installation/InstalledAppProbe.swift').read_text()
        derivation = probe.split('static func derive(', 1)[1].split('var title:', 1)[0]
        self.assertIn('!deviceVersion.isEmpty else { return .unknown }', derivation)
        history = (APP / 'Infrastructure/Tasks/UnifiedTaskModels.swift').read_text()
        self.assertIn('historical-installation-not-verified', history)
        self.assertIn('task.phase = .unconfirmed', history)
        self.assertIn('task.restoredFromHistory = true', history)
        receipt = (APP / 'Infrastructure/Tasks/TaskReceipt.swift').read_text()
        self.assertIn('missing handoff record does not prove nothing was sent', receipt)
        self.assertIn('historical: task.restoredFromHistory', receipt)
        summary = (APP / 'Infrastructure/Devices/Installation/InstallEvidenceSummary.swift').read_text()
        self.assertIn('historical || reason == "historical-installation-not-verified" ? .unknown', summary)

    def test_inventory_uses_the_identity_checked_adapter_and_its_typed_destructor(self):
        source = (VENDOR / 'DeviceServiceSession+Applications.swift').read_text()
        self.assertIn('app_service_connect_rsd(adapter, handshake, &client)', source)
        self.assertIn('defer { if let client { app_service_free(client) } }', source)
        self.assertIn('app_service_free_app_list(entries, count)', source)
        self.assertIn('DeviceApplicationInventory.maximumEntries', source)
        self.assertIn('encoding: .utf8', source)
        self.assertIn('entry.bundle_version', source)
        self.assertIn('entry.version', source)
        code = '\n'.join(line for line in source.splitlines() if not line.lstrip().startswith('//'))
        for forbidden in ('installation_proxy_get_apps(', 'installation_proxy_browse(', 'idevice_outer_slice_free(', 'idevice_data_free('):
            self.assertNotIn(forbidden, code)

    def test_archive_hash_authorization_and_atomic_stop_precede_native_submission(self):
        source = self.text('VexSign/Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift')
        command = source.index('installation_proxy_install_with_callback(')
        for check in ('O_NOFOLLOW', 'S_IFREG', 'digest == target.packageSHA256', 'Self.sameArchive(before, after)',
                      'target.permitsSubmission(', 'try control.beginSubmission('):
            self.assertLess(source.index(check), command)
        self.assertIn('autoreleasepool {', source)
        self.assertIn('if !commandStarted || commandFinished', source)
        control = self.text('VexSign/Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/DeviceInstallationSubmission.swift')
        self.assertIn('public func stopBeforeSubmission()', control)
        self.assertIn('!$0.stopped', control)
        queue = (APP / 'Infrastructure/Devices/Installation/InstallQueueCore.swift').read_text()
        self.assertIn('installer?.stopPreparingForMonitoringEnd() == true', queue)

    def test_paired_package_admission_reuses_real_profile_and_cryptographic_seal_verifiers(self):
        source = (APP / 'Infrastructure/Devices/Installation/PairedInstallationValidation.swift').read_text()
        for check in ('ProvisioningProfileParser.parse(profileData)', 'SignatureVerifier.verify(bundleAt: root',
                      '.requireVerified()', 'plan.profileBoundComponents', 'ExecutablePreflight.inspectSlices(bytes)',
                      'deviceUDID: device.deviceIdentifier', 'signerExpiry'):
            self.assertIn(check, source)
        installer = (APP / 'Infrastructure/Devices/Installation/AppInstaller.swift').read_text()
        package = installer.split('private func _createPackage()', 1)[1].split('private func _serveForOTA(', 1)[0]
        self.assertLess(package.index('PairedInstallationValidation.verify('), package.index('handler.archive('))
        self.assertLess(package.index('handler.archive('), package.index('FileIntegrity.sha256('))
        self.assertIn('pairedTarget: pairedTarget', package)

    def test_queue_persists_the_actual_bound_observation_and_never_reconstructs_it(self):
        queue = (APP / 'Infrastructure/Devices/Installation/InstallQueueCore.swift').read_text()
        trace = (APP / 'Infrastructure/Tasks/TaskTrace.swift').read_text()
        for field in ('installedApplicationEvidence', 'expectedDeviceBinding', 'nativeAcknowledgedAt', 'installationPackageSHA256'):
            self.assertIn(field, queue)
            self.assertIn(f'forKey: .{field}', trace)
        self.assertIn('task.context?.installedApplicationEvidence = evidence', queue)
        history = (APP / 'Infrastructure/Tasks/UnifiedTaskModels.swift').read_text()
        self.assertIn('hasConfirmedInstallation(notAfter: task.updatedAt) != true', history)
        library = (APP / 'Infrastructure/Persistence/Repositories/LibraryStatusStore.swift').read_text()
        self.assertIn('guard selectedDeviceBinding == evidence.deviceBinding else { return }', library)
        self.assertIn('receipt.app.evidence?.deviceBinding == binding', library)
        self.assertNotIn('InstalledApp(bundleIdentifier:', library)

    def test_only_explicit_setup_selection_is_eligible_and_revocation_invalidates_it(self):
        bridge = (APP / 'Infrastructure/Devices/Transport/PairingBridge.swift').read_text()
        self.assertIn('@MainActor private static var selectedDeviceRequest', bridge)
        request = bridge.split('static func installationRequest()', 1)[1].split('static func queryInstalledApplication(', 1)[0]
        self.assertIn('guard let request = selectedDeviceRequest', request)
        self.assertIn('metadata.sha256 == request.expectedPairingSHA256', request)
        self.assertNotIn('metadata.deviceIdentifier', request)
        self.assertIn('selectedDeviceRequest = nil', bridge)
        probe = (APP / 'Infrastructure/Devices/Installation/InstalledAppProbe.swift').read_text()
        paired = probe.split('struct PairedDeviceInstallationProbe:', 1)[1].split('struct UnavailableInstallationProbe:', 1)[0]
        self.assertEqual(paired.count('PairingBridge.isSelectedForUse(request)'), 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
