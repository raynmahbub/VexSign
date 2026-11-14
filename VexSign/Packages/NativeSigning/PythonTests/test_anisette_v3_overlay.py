import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
REPO = Path(__file__).resolve().parents[4]
SPEC = importlib.util.spec_from_file_location('anisette_preparation', HERE / "prepare_smoke.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class AnisetteOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.deps = self.root / 'Dependencies'
        self.specs = {}
        for name in ['AnisetteDataManager.swift', 'RemoteAnisetteDataProvider.swift']:
            relative = 'Sources/Anisette/' + name
            upstream = self.deps / 'sidesign' / relative
            local = self.root / 'VexSign/Packages/SideSign' / relative
            upstream.parent.mkdir(parents=True, exist_ok=True)
            local.parent.mkdir(parents=True, exist_ok=True)
            upstream.write_bytes(b'locked upstream fixture')
            local.write_bytes(b'reviewed local fixture')
            self.specs[relative] = {'upstream_sha256': module.digest(upstream.read_bytes()),
                                    'overlay_sha256': module.digest(local.read_bytes())}
        self.lock = {'anisette_v3_overlay': self.specs}
        self.root_patch = patch.object(module, 'ROOT', self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)

    def test_private_key_export_consumes_grant_inside_authoritative_bridge(self):
        root = REPO
        bridge = (root / 'VexSign/Packages/NativeSigning/Authentication/SideSignAccountBridge.swift').read_text()
        backend = (root / 'VexSign/Packages/NativeSigning/Authentication/NativeAccountBackend.swift').read_text()
        body = bridge.split('func exportSigningIdentity(', 1)[1].split('/// Offline positive cache', 1)[0]
        self.assertLess(body.index('keyExportConsent.begin('), body.index('signingIdentities.privateKeyDER('))
        self.assertLess(body.index('signingIdentities.privateKeyDER('), body.index('NativeSigningIdentityCrypto.exportPKCS12('))
        self.assertGreaterEqual(body.count('epoch == keyExportEpoch'), 3)
        self.assertNotIn('keyExportMaterial(', backend)
        self.assertGreaterEqual(bridge.count('await revokeKeyExportConsent()'), 2)

    def test_reviewed_sources_are_copied_exactly(self):
        result = module.apply_anisette_v3_overlay(self.deps, self.lock)
        self.assertEqual(result, self.specs)
        for relative in self.specs:
            self.assertEqual((self.deps / 'sidesign' / relative).read_bytes(),
                             (self.root / 'VexSign/Packages/SideSign' / relative).read_bytes())

    def test_upstream_or_overlay_drift_is_rejected(self):
        first = next(iter(self.specs))
        upstream = self.deps / 'sidesign' / first
        upstream.write_bytes(b'changed upstream')
        with self.assertRaisesRegex(ValueError, 'upstream source changed'):
            module.apply_anisette_v3_overlay(self.deps, self.lock)
        upstream.write_bytes(b'locked upstream fixture')
        (self.root / 'VexSign/Packages/SideSign' / first).write_bytes(b'changed local overlay')
        with self.assertRaisesRegex(ValueError, 'overlay changed'):
            module.apply_anisette_v3_overlay(self.deps, self.lock)

    def test_incomplete_review_or_path_injection_is_rejected(self):
        for specs in [{}, {'../../outside.swift': {}}]:
            with self.assertRaisesRegex(ValueError, 'Incomplete anisette'):
                module.apply_anisette_v3_overlay(self.deps, {'anisette_v3_overlay': specs})

    def test_platform_and_package_keychain_enumeration_cannot_drift(self):
        platform = (REPO / "VexSign/App/iOS/VexSign/Security/Secrets/AppleAccountResumeJournalStore.swift").read_bytes()
        native = (HERE / "Security/AppleAccountResumeJournalStore.swift").read_bytes()
        self.assertEqual(platform, native)
        self.assertIn(b'(errSecUnimplemented, [])', native)
        self.assertIn(b'return (errSecDecode, [])', native)

    def test_provisioning_ui_never_simulates_signing_or_guesses_registration_ids(self):
        source = (REPO / "VexSign/App/iOS/VexSign/Presentation/Features/Accounts/Views/ProvisioningFlowView.swift").read_text()
        self.assertNotIn('simulate completion', source)
        self.assertNotIn('Task.sleep', source)
        self.assertNotIn('registeredDeviceID: "auto"', source)
        self.assertNotIn('plan.existingAppIdentifiers.first', source)
        adapter = (REPO / "VexSign/App/iOS/VexSign/Infrastructure/Accounts/AppleAccountWorkspaceAdapter.swift").read_text()
        policy = (REPO / "VexSign/App/iOS/VexSign/Application/Accounts/AppleAccountWorkspaceUseCase.swift").read_text()
        self.assertIn('appRegistration: appRegistration', adapter)
        self.assertIn('deviceRegistration: deviceRegistration', adapter)
        self.assertLess(adapter.index('try await manager.requireProfileOperations()'), adapter.index('try await manager.provisioningPreflight('))
        self.assertIn('certificate: approveCertificate', source)
        self.assertIn('registration: approveRegistration, profile: approveProfile', source)
        self.assertIn('guard approval.isComplete', policy)
        self.assertNotIn('NativeSigningManager', source)
        self.assertNotIn('Task.sleep', adapter)
        self.assertIn('.interactiveDismissDisabled(isProvisioning)', source)

    def test_background_discovery_cannot_manufacture_mutation_approvals(self):
        source = (REPO / "VexSign/App/iOS/VexSign/Infrastructure/Accounts/NativeSigningManager.swift").read_text()
        marker = 'func refreshRenewalCandidates()'
        self.assertIn(marker, source, 'the read-only renewal refresh no longer exists under its honest name')
        renewal = source.split(marker, 1)[1].split('// MARK: - Backend Initialization', 1)[0]
        self.assertIn('fetchActiveFreeAccountProfiles()', renewal)
        self.assertNotIn('recordCertificateCreationApproval', renewal)
        self.assertNotIn('recordRegistrationApproval', renewal)
        self.assertNotIn('recordProfileCreationApproval', renewal)
        self.assertNotIn('registeredDeviceID: "auto"', source)


if __name__ == '__main__':
    unittest.main()
