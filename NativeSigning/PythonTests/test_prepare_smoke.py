import importlib.util
import json
import re
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location('prepare_smoke', HERE / 'prepare_smoke.py')
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.known = {'swift-crypto': {'repository': 'https://github.com/apple/swift-crypto.git'}}

    def test_remote_constraints_become_pinned_local_packages(self):
        for requirement in ['branch: "main"', 'revision: "abc"', 'exact: "4.3.1"', 'from: "4.0.0"']:
            source = f'.package(url: "https://github.com/apple/swift-crypto.git", {requirement})'
            result = module.rewrite_dependencies(source, self.known)
            self.assertIn('path: "../swift-crypto"', result)
            self.assertNotIn('https:', result)

    def test_unknown_sources_and_unhandled_constraints_fail_closed(self):
        for source in [
            '.package(url: "https://github.com/other/swift-crypto.git", branch: "main")',
            '.package(url: "https://github.com/other/unknown.git", branch: "main")',
            '.package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"2.0.0")'
        ]:
            with self.assertRaises(ValueError):
                module.rewrite_dependencies(source, self.known)

    def test_modified_manifests_are_rejected_before_rewrite(self):
        package = self.root / 'package'
        package.mkdir()
        (package / 'Package.swift').write_text('modified source')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            module.patch_manifest(package, '0' * 64, self.known, self.root / 'originals')

    def test_manifest_overlay_preserves_original_and_removes_stale_resolution(self):
        package = self.root / 'package'
        package.mkdir()
        raw = b'.package(url: "https://github.com/apple/swift-crypto.git", branch: "main")'
        (package / 'Package.swift').write_bytes(raw)
        (package / 'Package.resolved').write_text('stale')
        hashes = module.patch_manifest(package, module.digest(raw), self.known, self.root / 'originals')
        self.assertEqual((self.root / 'originals/package.swift.txt').read_bytes(), raw)
        self.assertNotEqual(hashes['original_sha256'], hashes['overlay_sha256'])
        self.assertFalse((package / 'Package.resolved').exists())

    def test_unreviewed_version_specific_manifest_is_rejected(self):
        package = self.root / 'package'
        package.mkdir()
        (package / 'Package.swift').write_text('')
        (package / 'Package@swift-6.0.swift').write_text('unexpected')
        with self.assertRaisesRegex(ValueError, 'alternate'):
            module.patch_manifest(package, module.digest(b''), {}, self.root / 'originals')

    def test_library_overlays_omit_only_unneeded_targets_and_keep_crypto_products(self):
        for name in ['CodeSignKit', 'GSACryptoKit']:
            text = module.library_manifest(name)
            self.assertIn(f'name: "{name}"', text)
            self.assertIn('path: "Sources"', text)
            self.assertIn('CryptoExtras', text)
            self.assertNotIn('binaryTarget', text)
            self.assertNotIn('OpenSSL', text)
            self.assertNotIn('testTarget', text)
        self.assertIn('SwiftASN1', module.library_manifest('CodeSignKit'))

    def test_locked_source_graph_matches_the_existing_app_signer(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        module.check_app_baseline(lock)
        for spec in lock['packages'].values():
            self.assertRegex(spec['commit'], r'^[0-9a-f]{40}$')
            self.assertRegex(spec['manifest_sha256'], r'^[0-9a-f]{64}$')
        self.assertIn('swift-asn1', lock['packages'])
        self.assertIn('openssl', lock['packages'])

    def test_installed_codec_and_tests_match_first_party_source_hashes(self):
        hashes = module.install_smoke_sources(self.root)
        # 107 = the previous 106 plus the OpenSSL-built CMS fixture that backs the
        # OpenSSLBuilt cases in NativeAppleProfileCMSTests. The smoke package's
        # test target declares it as a resource, so it must be staged with them.
        self.assertEqual(len(hashes), 107)
        self.assertIn('Provisioning/VexSignProfileTypes.swift', hashes)
        self.assertIn('Fixtures/cms_v1_sha256_rsa.der', hashes)
        # The smoke graph must compile every production implementation, including
        # byte-identical app lifecycle/storage mirrors. A source-count assertion
        # alone missed the local DTOs and silently resolved imported SDK types.
        staged = {module.digest(path.read_bytes()) for path in
                  (self.root / 'Sources/NativeSigningLinkSmoke').glob('*.swift')}
        for folder in ('Authentication', 'Codec', 'Identity', 'Provisioning', 'Security', 'Services', 'Signing'):
            for source in (HERE / folder).rglob('*.swift'):
                self.assertIn(module.digest(source.read_bytes()), staged,
                              f'Production implementation missing from smoke graph: {source.relative_to(HERE)}')
        for relative, checksum in hashes.items():
            source = (HERE.parent if relative.startswith('VexSign/') else HERE) / relative
            self.assertEqual(module.digest(source.read_bytes()), checksum)
        for name in ['AppleAccountAuthenticationState', 'AppleAccountSessionCoordinator', 'AppleAccountSessionRepository']:
            self.assertEqual((self.root / 'Sources/NativeSigningLinkSmoke' / (name + '.swift')).read_bytes(),
                             (HERE.parent / 'VexSign/Backend/Services' / (name + '.swift')).read_bytes())
        self.assertEqual(
            (self.root / 'Sources/NativeSigningLinkSmoke/SideSignSessionCodec.swift').read_bytes(),
            (HERE / 'Codec/SideSignSessionCodec.swift').read_bytes())
        self.assertTrue((self.root / 'Tests/NativeSigningCodecTests/SideSignSessionCodecTests.swift').is_file())
        self.assertIn('.testTarget(name: "NativeSigningCodecTests"', (self.root / 'Package.swift').read_text())

    def test_prepared_graph_includes_concrete_provider_and_its_tests(self):
        module.install_smoke_sources(self.root)
        for directory, name in [('Sources/NativeSigningLinkSmoke', 'HTTPSAnisetteProvider.swift'),
                                ('Tests/NativeSigningCodecTests', 'HTTPSAnisetteProviderTests.swift')]:
            self.assertTrue((self.root / directory / name).is_file())
        self.assertIn('anisetteProviderFactory', (self.root / 'Sources/NativeSigningLinkSmoke/LinkSmoke.swift').read_text())

    def test_assembly_uses_actual_platform_stores_and_lifetime_guard(self):
        module.install_smoke_sources(self.root)
        for name in ['AppleAccountCredentialStore', 'AppleAccountResumeJournalStore', 'AppleAccountStorageRuntimePolicy']:
            actual = (self.root / 'Sources/NativeSigningLinkSmoke' / (name + '.swift')).read_bytes()
            self.assertEqual(actual, (HERE.parent / 'VexSign/Security' / (name + '.swift')).read_bytes())
            self.assertNotIn(b'import NimbleExtensions', actual)
        self.assertTrue((self.root / 'Tests/NativeSigningCodecTests/NativeAccountBackendTests.swift').is_file())
        self.assertIn('accountBackendFactory', (self.root / 'Sources/NativeSigningLinkSmoke/LinkSmoke.swift').read_text())
        bridge = (self.root / 'Sources/NativeSigningLinkSmoke/SideSignAccountBridge.swift').read_text()
        self.assertIn('private let lifetime: (any NativeAccountBackendLifetime)?', bridge)
        # Foundation extraction must not silently orphan the four localized errors.
        vault = (HERE.parent / 'VexSign/Security/AppleAccountCredentialStore.swift').read_text()
        keys = re.findall(r'NSLocalizedString\("([^"\n]+)"', vault)
        catalogue = json.loads((HERE.parent / 'VexSign/Resources/Localizable.xcstrings').read_text())['strings']
        self.assertEqual(len(keys), 4)
        self.assertTrue(all(key in catalogue for key in keys))

    def test_provisioning_sources_and_future_native_cases_enter_the_graph(self):
        module.install_smoke_sources(self.root)
        for name in ['NativeAccountProvisioningPlan', 'SideSignProvisioningAdapter']:
            self.assertTrue((self.root / 'Sources/NativeSigningLinkSmoke' / (name + '.swift')).is_file())
        self.assertTrue((self.root / 'Tests/NativeSigningCodecTests/NativeProvisioningPlanTests.swift').is_file())

    def test_identity_vault_and_deferred_native_cases_enter_the_graph(self):
        module.install_smoke_sources(self.root)
        for name in ['NativeSigningIdentity', 'NativeSigningIdentityCrypto', 'NativeSigningIdentityKeychainStore']:
            self.assertTrue((self.root / 'Sources/NativeSigningLinkSmoke' / (name + '.swift')).is_file())
        self.assertTrue((self.root / 'Tests/NativeSigningCodecTests/NativeSigningIdentityTests.swift').is_file())

    def test_csr_overlay_is_pinned_and_registered_without_running_it(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        source = HERE / 'patches/VexSignPreparedCSR.swift'
        self.assertEqual(module.digest(source.read_bytes()), lock['csr_overlay']['sha256'])
        module.install_smoke_sources(self.root)
        for name in ['NativeCertificateCreationApproval', 'SideSignCertificateAdapter']:
            self.assertTrue((self.root / 'Sources/NativeSigningLinkSmoke' / (name + '.swift')).is_file())
        self.assertTrue((self.root / 'Tests/NativeSigningCodecTests/NativeCertificateCreationTests.swift').is_file())

    def test_csr_overlay_checks_upstream_hashes_and_refuses_overwrite(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        deps = self.root / 'Dependencies'
        for relative in lock['csr_overlay']['reviewed_sources']:
            path = deps / 'sidesign' / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            raw = ('synthetic reviewed source ' + relative).encode()
            path.write_bytes(raw)
            lock['csr_overlay']['reviewed_sources'][relative] = module.digest(raw)
        module.apply_csr_overlay(deps, lock)
        destination = deps / 'sidesign' / lock['csr_overlay']['path']
        self.assertEqual(destination.read_bytes(), (HERE / 'patches/VexSignPreparedCSR.swift').read_bytes())
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            module.apply_csr_overlay(deps, lock)

    def test_csr_overlay_rejects_unreviewed_dispatcher_before_copy(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        deps = self.root / 'Dependencies'
        for relative in lock['csr_overlay']['reviewed_sources']:
            path = deps / 'sidesign' / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('source drift')
        with self.assertRaisesRegex(ValueError, 'upstream source changed'):
            module.apply_csr_overlay(deps, lock)
        self.assertFalse((deps / 'sidesign' / lock['csr_overlay']['path']).exists())

    def test_profile_validation_sources_registered_without_running_native_code(self):
        hashes = module.install_smoke_sources(self.root)
        self.assertIn('Provisioning/NativeProvisioningProfileValidator.swift', hashes)
        self.assertIn('Tests/NativeProvisioningProfileTests.swift', hashes)
        self.assertTrue((self.root / 'Sources/NativeSigningLinkSmoke/NativeProvisioningProfileValidator.swift').is_file())
        self.assertTrue((self.root / 'Tests/NativeSigningCodecTests/NativeProvisioningProfileTests.swift').is_file())

    def test_registration_executor_sources_are_in_provenance(self):
        hashes = module.install_smoke_sources(self.root)
        for relative in ['Provisioning/NativeRegistrationExecutor.swift', 'Provisioning/NativeRegistrationKeychainStore.swift', 'Tests/NativeRegistrationExecutorTests.swift']:
            self.assertIn(relative, hashes)

    def test_registration_transport_overlay_hash_registration_and_overwrite_guard(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        spec = lock['registration_overlay']
        source = HERE / 'patches/VexSignRegistration.swift'
        self.assertEqual(module.digest(source.read_bytes()), spec['sha256'])
        self.assertEqual(len(spec['reviewed_sources']), 6)
        deps = self.root / 'Dependencies'
        for relative in spec['reviewed_sources']:
            path = deps / 'sidesign' / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            raw = ('reviewed fixture ' + relative).encode()
            path.write_bytes(raw)
            spec['reviewed_sources'][relative] = module.digest(raw)
        module.apply_registration_overlay(deps, lock)
        self.assertEqual((deps / 'sidesign' / spec['path']).read_bytes(), source.read_bytes())
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            module.apply_registration_overlay(deps, lock)
        hashes = module.install_smoke_sources(self.root)
        self.assertIn('Provisioning/SideSignRegistrationTransport.swift', hashes)
        self.assertIn('Provisioning/SideSignBoundRegistrationPortal.swift', hashes)
        self.assertIn('Tests/NativeRegistrationTransportTests.swift', hashes)

    def test_registration_transport_rejects_wire_drift_before_install(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        spec = lock['registration_overlay']; deps = self.root / 'Dependencies'
        for relative in spec['reviewed_sources']:
            path = deps / 'sidesign' / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('unreviewed upstream')
        with self.assertRaisesRegex(ValueError, 'upstream source changed'):
            module.apply_registration_overlay(deps, lock)
        self.assertFalse((deps / 'sidesign' / spec['path']).exists())

    def test_registration_approval_is_in_native_provenance(self):
        hashes = module.install_smoke_sources(self.root)
        self.assertIn('Provisioning/NativeAccountRegistrationApproval.swift', hashes)
        self.assertTrue((self.root / 'Sources/NativeSigningLinkSmoke/NativeAccountRegistrationApproval.swift').is_file())

    def test_profile_creation_core_is_in_provenance(self):
        hashes = module.install_smoke_sources(self.root)
        for relative in ['Provisioning/NativeProfileCreation.swift', 'Provisioning/NativeProfileCreationExecutor.swift', 'Provisioning/NativeProfileCreationKeychainStore.swift', 'Tests/NativeProfileCreationTests.swift']:
            self.assertIn(relative, hashes)

    def test_profile_transport_source_provenance_and_overwrite_guard(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        spec = lock['profile_overlay']; deps = self.root / 'Dependencies'
        source = HERE / 'patches/VexSignProfiles.swift'
        self.assertEqual(module.digest(source.read_bytes()), spec['sha256'])
        transport = deps / 'sidesign/Sources/VexSignRegistration.swift'
        transport.parent.mkdir(parents=True, exist_ok=True)
        transport.write_bytes((HERE / 'patches/VexSignRegistration.swift').read_bytes())
        for relative in spec['reviewed_sources']:
            path = deps / 'sidesign' / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            raw = ('reviewed fixture ' + relative).encode(); path.write_bytes(raw)
            spec['reviewed_sources'][relative] = module.digest(raw)
        module.apply_profile_overlay(deps, lock)
        self.assertEqual((deps / 'sidesign' / spec['path']).read_bytes(), source.read_bytes())
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            module.apply_profile_overlay(deps, lock)
        hashes = module.install_smoke_sources(self.root)
        self.assertIn('Provisioning/SideSignProfileTransport.swift', hashes)
        self.assertIn('Tests/NativeProfileTransportTests.swift', hashes)

    def test_profile_transport_rejects_changed_shared_transport_before_copy(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text()); deps = self.root / 'Dependencies'
        transport = deps / 'sidesign/Sources/VexSignRegistration.swift'
        transport.parent.mkdir(parents=True, exist_ok=True); transport.write_text('unreviewed transport')
        with self.assertRaisesRegex(ValueError, 'transport dependency changed'):
            module.apply_profile_overlay(deps, lock)
        self.assertFalse((deps / 'sidesign' / lock['profile_overlay']['path']).exists())

    def test_bound_profile_and_resource_policy_in_provenance(self):
        hashes = module.install_smoke_sources(self.root)
        for relative in ['Provisioning/SideSignBoundProfilePortal.swift', 'Provisioning/NativeProfileResourcePolicy.swift', 'Tests/NativeProfileResourceTests.swift']:
            self.assertIn(relative, hashes)

    def test_certificate_inventory_overlay_hashes_and_overwrite_guard(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        spec = lock['certificate_inventory_overlay']; deps = self.root / 'Dependencies'
        source = HERE / 'patches/VexSignCertificateInventory.swift'
        self.assertEqual(module.digest(source.read_bytes()), spec['sha256'])
        transport = deps / 'sidesign/Sources/VexSignRegistration.swift'
        transport.parent.mkdir(parents=True, exist_ok=True)
        transport.write_bytes((HERE / 'patches/VexSignRegistration.swift').read_bytes())
        for relative in spec['reviewed_sources']:
            path = deps / 'sidesign' / relative; path.parent.mkdir(parents=True, exist_ok=True)
            raw = ('reviewed fixture ' + relative).encode(); path.write_bytes(raw)
            spec['reviewed_sources'][relative] = module.digest(raw)
        module.apply_certificate_inventory_overlay(deps, lock)
        self.assertEqual((deps / 'sidesign' / spec['path']).read_bytes(), source.read_bytes())
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            module.apply_certificate_inventory_overlay(deps, lock)
        hashes = module.install_smoke_sources(self.root)
        self.assertIn('Provisioning/NativeProfileCertificateInventoryPolicy.swift', hashes)
        self.assertIn('Tests/NativeProfileCertificateInventoryTests.swift', hashes)

    def test_certificate_inventory_rejects_unreviewed_transport(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text()); deps = self.root / 'Dependencies'
        transport = deps / 'sidesign/Sources/VexSignRegistration.swift'
        transport.parent.mkdir(parents=True, exist_ok=True); transport.write_text('unreviewed')
        with self.assertRaisesRegex(ValueError, 'transport dependency changed'):
            module.apply_certificate_inventory_overlay(deps, lock)
        self.assertFalse((deps / 'sidesign' / lock['certificate_inventory_overlay']['path']).exists())

    def test_apple_cms_sources_and_review_are_in_provenance(self):
        hashes = module.install_smoke_sources(self.root)
        for relative in ['Provisioning/NativeProfileDER.swift', 'Provisioning/NativeProfileCMSEnvelope.swift', 'Provisioning/NativeAppleProfileCMSVerifier.swift', 'Tests/NativeAppleProfileCMSTests.swift', 'apple-cms-policy-review.json']:
            self.assertIn(relative, hashes)
        review = json.loads((HERE / 'apple-cms-policy-review.json').read_text())
        verifier = (HERE / 'Provisioning/NativeAppleProfileCMSVerifier.swift').read_text()
        self.assertEqual(len(review['root_sources']), 3)
        for root in review['root_sources']:
            self.assertIn(root['sha256'], verifier)

    def test_profile_facade_sources_and_shared_gate_are_registered(self):
        hashes = module.install_smoke_sources(self.root)
        for relative in ['Provisioning/NativeAccountProfileOperation.swift', 'Tests/NativeAccountProfileOperationTests.swift']:
            self.assertIn(relative, hashes)
        bridge = (HERE / 'Authentication/SideSignAccountBridge.swift').read_text()
        backend = (HERE / 'Authentication/NativeAccountBackend.swift').read_text()
        for name in ['recordExplicitProfileCreationApproval', 'revokeProfileCreationApproval', 'createAccountProvisioningProfile', 'reconcileAccountProvisioningProfile']:
            self.assertIn(name, bridge)
            self.assertIn(name, backend)
        self.assertNotIn('registrationTask == nil else', bridge)
        self.assertIn('profileValidator: NativeProvisioningProfileValidator = .init()', bridge)
        # Normal public factory must not silently promote the unvalidated verifier.
        self.assertNotIn('.appleCMS()', backend)

    def test_main_app_acceptance_inputs_and_profile_binding_are_registered(self):
        hashes = module.install_smoke_sources(self.root)
        for relative in ['Identity/NativeMachOInspection.swift', 'Identity/NativeMainAppAcceptance.swift', 'Tests/NativeMainAppAcceptanceTests.swift']:
            self.assertIn(relative, hashes)
        validator = (HERE / 'Provisioning/NativeProvisioningProfileValidator.swift').read_text()
        self.assertIn('certificateSHA256: NativeSigningIdentityOwner.hash(request.certificateDER)', validator)
        self.assertIn('deviceIdentifier: request.deviceIdentifier', validator)
        backend = (HERE / 'Authentication/NativeAccountBackend.swift').read_text()
        self.assertNotIn('NativeAccountSigningCandidate', backend)

    def test_archive_index_and_layout_sources_are_registered_without_promoting_signing(self):
        hashes = module.install_smoke_sources(self.root)
        for relative in ['Identity/NativeIPAArchiveIndex.swift', 'Identity/NativeIPAArchiveLayout.swift', 'Tests/NativeIPAArchiveTests.swift']:
            self.assertIn(relative, hashes)
        index = (HERE / 'Identity/NativeIPAArchiveIndex.swift').read_text()
        self.assertIn('content unverified', index)
        backend = (HERE / 'Authentication/NativeAccountBackend.swift').read_text()
        self.assertNotIn('NativeIPAArchiveIndex', backend)

    def test_content_decoder_verifier_and_public_receipt_sources_are_registered(self):
        hashes = module.install_smoke_sources(self.root)
        for relative in ['Identity/NativeIPAEntryDecoder.swift', 'Identity/NativeIPAContentVerifier.swift', 'Identity/NativeIPAContentInspection.swift', 'Tests/NativeIPAContentTests.swift']:
            self.assertIn(relative, hashes)
        verifier = (HERE / 'Identity/NativeIPAContentVerifier.swift').read_text()
        self.assertIn('for entry in index.entries', verifier)
        self.assertIn('NativeIPAEntryDecoder.decode', verifier)
        backend = (HERE / 'Authentication/NativeAccountBackend.swift').read_text()
        self.assertNotIn('.appleCMS()', backend)

    def test_development_trust_and_protected_handoff_sources_are_registered(self):
        hashes = module.install_smoke_sources(self.root)
        for relative in ['Identity/NativeDevelopmentCertificatePurpose.swift', 'Identity/NativeDevelopmentCertificateVerifier.swift', 'Identity/NativeProtectedSigningHandoff.swift', 'Tests/NativeDevelopmentCertificateTests.swift', 'development-certificate-review.json']:
            self.assertIn(relative, hashes)
        verifier = (HERE / 'Identity/NativeDevelopmentCertificateVerifier.swift').read_text()
        self.assertIn('kSecRevocationRequirePositiveResponse', verifier)
        self.assertIn('kSecRevocationNetworkAccessDisabled', verifier)
        review = json.loads((HERE / 'development-certificate-review.json').read_text())
        for root in review['root_sources']:
            self.assertIn(root['sha256'], verifier)
        handoff = (HERE / 'Identity/NativeProtectedSigningHandoff.swift').read_text()
        self.assertIn('NativeIPAContentVerifier.verify', handoff)
        self.assertNotIn('exportP12', handoff)

    def test_status_consent_issuer_and_public_bridge_are_registered(self):
        hashes = module.install_smoke_sources(self.root)
        for relative in ['Identity/NativeCertificateStatusConsent.swift', 'Identity/NativeDevelopmentIssuerStore.swift', 'Tests/NativeCertificateStatusConsentTests.swift']:
            self.assertIn(relative, hashes)
        bridge = (HERE / 'Authentication/SideSignAccountBridge.swift').read_text()
        facade = (HERE / 'Authentication/NativeAccountBackend.swift').read_text()
        for name in ['recordExplicitCertificateStatusConsent', 'revokeCertificateStatusConsent', 'evaluateSigningCertificateStatus']:
            self.assertIn(name, bridge)
            self.assertIn(name, facade)
        self.assertNotIn('profileTask == nil else', bridge)
        review = json.loads((HERE / 'development-certificate-review.json').read_text())
        self.assertIn(review['issuer_supply']['certificate_der_sha256'], (HERE / 'Identity/NativeDevelopmentIssuerStore.swift').read_text())

    def test_output_consistency_and_transport_sources_registered(self):
        hashes = module.install_smoke_sources(self.root)
        for path in ['Signing/NativeDetachedCodeSignatureVerifier.swift', 'Signing/NativeCodeDirectoryVerifier.swift', 'Signing/NativeStoredZIPWriter.swift', 'Tests/NativeSignedOutputTests.swift']:
            self.assertIn(path, hashes)

    def test_der_correction_fails_closed_on_unreviewed_source(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        source = self.root / 'codesignkit/Sources/DEREncoder.swift'
        source.parent.mkdir(parents=True)
        source.write_text('unreviewed')
        with self.assertRaisesRegex(ValueError, 'source changed'):
            module.apply_der_boolean_correction(self.root, lock, self.root / 'originals')
        self.assertEqual(source.read_text(), 'unreviewed')

    def test_composed_signature_claims_and_resource_policy_are_registered(self):
        hashes = module.install_smoke_sources(self.root)
        for path in ['Signing/NativeOutputEntitlements.swift', 'Signing/NativeStrictCodeResources.swift', 'Signing/NativeResourceSealVerifier.swift', 'Signing/NativeMainSignatureConsistency.swift', 'Tests/NativeOutputPolicyTests.swift']:
            self.assertIn(path, hashes)
        source = (HERE / 'Signing/NativeMainSignatureConsistency.swift').read_text()
        for primitive in ['NativeOutputEntitlements.verify', 'NativeCodeDirectoryVerifier.verify', 'NativeDetachedCodeSignatureVerifier.verify']:
            self.assertIn(primitive, source)
        resources = (HERE / 'Signing/NativeResourceSealVerifier.swift').read_text()
        for required in ['NativeIPAEntryDecoder.decode', 'NativeStrictCodeResources.encode', 'content.entrySHA256', 'expectedProfileCMS']:
            self.assertIn(required, resources)

    def test_macho_mutation_and_image_signature_entry_point_are_registered(self):
        hashes = module.install_smoke_sources(self.root)
        for path in ['Signing/NativeMachOMutationVerifier.swift', 'Tests/NativeMachOMutationTests.swift']:
            self.assertIn(path, hashes)
        source = (HERE / 'Signing/NativeMainSignatureConsistency.swift').read_text()
        self.assertIn('verifyMutationAndSignature', source)
        self.assertIn('NativeMachOMutationVerifier.verify', source)
        self.assertIn('mutation.signatureRange', source)

    def test_designated_requirement_policy_is_registered_and_enforced(self):
        hashes = module.install_smoke_sources(self.root)
        for path in ['Signing/NativeDesignatedRequirement.swift', 'Tests/NativeDesignatedRequirementTests.swift', 'designated-requirement-review.json']:
            self.assertIn(path, hashes)
        source = (HERE / 'Signing/NativeMainSignatureConsistency.swift').read_text()
        self.assertIn('NativeDesignatedRequirement.verify(requirements', source)
        review = json.loads((HERE / 'designated-requirement-review.json').read_text())
        self.assertEqual(review['constants']['leaf_slot'], 0)
        self.assertEqual(len(review['sources']), 4)
        for reviewed in review['sources']:
            self.assertRegex(reviewed['sha256'], r'^[0-9a-f]{64}$')

    def test_loader_envelope_is_registered_and_image_bound(self):
        hashes = module.install_smoke_sources(self.root)
        for path in ['Signing/NativeMachOLoaderPolicy.swift', 'Tests/NativeMachOLoaderPolicyTests.swift']:
            self.assertIn(path, hashes)
        source = (HERE / 'Signing/NativeMainSignatureConsistency.swift').read_text()
        self.assertIn('NativeMachOLoaderPolicy.validate(original)', source)
        self.assertIn('NativeMachOLoaderPolicy.validate(output)', source)

    def test_legacy_dyld_decoder_is_registered_and_loader_uses_it(self):
        hashes = module.install_smoke_sources(self.root)
        for path in ['Signing/NativeDyldBytecode.swift', 'Tests/NativeDyldBytecodeTests.swift']:
            self.assertIn(path, hashes)
        loader = (HERE / 'Signing/NativeMachOLoaderPolicy.swift').read_text()
        self.assertIn('NativeDyldBytecode.validate', loader)
        self.assertIn('case 0x80000034:', loader)

    def test_export_trie_decoder_is_registered_and_used_by_both_commands(self):
        hashes = module.install_smoke_sources(self.root)
        for path in ['Signing/NativeExportTrie.swift', 'Tests/NativeExportTrieTests.swift']:
            self.assertIn(path, hashes)
        source = (HERE / 'Signing/NativeMachOLoaderPolicy.swift').read_text()
        self.assertEqual(source.count('NativeExportTrie.validate('), 2)
        self.assertIn('case 0x80000033:', source)
        self.assertIn('word(p + 44) == 0', source)

    def test_restricted_chained_fixup_decoder_is_registered_and_used(self):
        hashes = module.install_smoke_sources(self.root)
        for path in ['Signing/NativeChainedFixups.swift', 'Tests/NativeChainedFixupsTests.swift']:
            self.assertIn(path, hashes)
        loader = (HERE / 'Signing/NativeMachOLoaderPolicy.swift').read_text()
        self.assertIn('NativeChainedFixups.validate', loader)
        self.assertIn('for field in [12, 20, 36]', loader)

    def test_whole_output_auditor_and_linkedit_metadata_are_registered(self):
        hashes = module.install_smoke_sources(self.root)
        for path in ['Signing/NativeLinkeditMetadata.swift', 'Signing/NativeSignedArchiveAuditor.swift', 'Tests/NativeLinkeditMetadataTests.swift']:
            self.assertIn(path, hashes)
        source = (HERE / 'Signing/NativeSignedArchiveAuditor.swift').read_text()
        for text in ['validator.requireCMSVerification()', 'factory.prepare', 'NativeResourceSealVerifier.verify', 'verifyMutationAndSignature', 'Task.detached', 'withTaskCancellationHandler']:
            self.assertIn(text, source)
        self.assertEqual(source.count('factory.prepare('), 2)

    def test_dependency_review_matches_current_app_pins_without_rewriting_them(self):
        review = json.loads((HERE / 'app-dependency-review.json').read_text())
        raw = (HERE.parent / review['app_pins_file']).read_bytes()
        self.assertEqual(module.digest(raw), review['app_pins_sha256'])
        pins = {p['identity']: p['state']['revision'] for p in json.loads(raw)['pins']}
        recorded = {p['identity']: p['revision'] for p in review['root_manifest_review']}
        self.assertEqual(recorded, pins)
        blocker = review['confirmed_blocker']
        self.assertEqual(blocker['identity'], 'vapor')
        self.assertEqual(blocker['isolated_version'], '4.3.1')
        self.assertEqual(blocker['requirement'], '1.0.0..<6.0.0')
        self.assertIn('version = 4.122.3;', (HERE.parent / 'VexSign.xcodeproj/project.pbxproj').read_text())

    def test_codec_revision_matches_reviewed_sdk_and_size_matches_vault(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        codec = (HERE / 'Codec/SideSignSessionCodec.swift').read_text()
        module.check_codec_baseline(lock)
        self.assertIn('sdkRevision = "' + lock['sidesign']['commit'] + '"', codec)
        self.assertIn('maximumBytes = 1024 * 1024', codec)
        vault = (HERE.parent / 'VexSign/Security/AppleAccountCredentialStore.swift').read_text()
        self.assertIn('maximumSessionBytes: Int { 1024 * 1024 }', vault)

    def test_sdk_revision_change_requires_a_codec_review(self):
        lock = json.loads((HERE / 'inputs.lock.json').read_text())
        lock['sidesign']['commit'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'persistence schema'):
            module.check_codec_baseline(lock)

    def test_logging_overlays_are_hash_checked_and_preserve_originals(self):
        deps = self.root / 'deps'
        specs = {}
        original = (
            'public enum CONFIG {\n    public static var isLoggingEnabled = true\n}\n'
            'public func debugLog(_ text: @autoclosure () -> String) {\n    print(text())\n}\n'
            'public func verboseLog(_ text: @autoclosure () -> String) {\n    print(text())\n}\n'
        )
        for package, config in [('sidesign', 'SideSignLogging'), ('anisettekit', 'AnisetteKitLogging')]:
            path = deps / package / 'Sources/Logging.swift'
            path.parent.mkdir(parents=True)
            raw = original.replace('CONFIG', config).encode()
            path.write_bytes(raw)
            specs[package] = {'path': 'Sources/Logging.swift', 'sha256': module.digest(raw)}
        originals = self.root / 'originals'
        overlays = module.apply_privacy_overlays(deps, {'privacy_sources': specs}, originals)
        self.assertEqual(set(overlays), {'sidesign', 'anisettekit'})
        for package in specs:
            patched = (deps / package / 'Sources/Logging.swift').read_text()
            self.assertNotIn('print(', patched)
            self.assertNotIn('text()', patched)
            self.assertIn('isLoggingEnabled: Bool { false }', patched)
            self.assertIn('loggingSuppressed', patched)
            self.assertNotEqual(overlays[package]['original_sha256'], overlays[package]['overlay_sha256'])
            self.assertEqual(module.digest((originals / package / 'Sources/Logging.swift').read_bytes()), specs[package]['sha256'])
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            module.apply_privacy_overlays(deps, {'privacy_sources': specs}, originals)

    def test_missing_or_unknown_privacy_inputs_fail_closed(self):
        with self.assertRaisesRegex(ValueError, 'Both logging overlays'):
            module.apply_privacy_overlays(self.root, {'privacy_sources': {}}, self.root / 'originals')
        with self.assertRaisesRegex(ValueError, 'Unreviewed'):
            module.apply_privacy_overlays(self.root, {'privacy_sources': {
                'unexpected': {'path': '../Logging.swift', 'sha256': '0' * 64}
            }}, self.root / 'originals')

    def test_logging_source_shape_changes_are_rejected(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('logging_overlay_test', HERE / 'patches/suppress_sdk_logging.py')
        overlay = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(overlay)
        with self.assertRaisesRegex(ValueError, 'configuration shape'):
            overlay.suppress_logging('changed API', 'sidesign')
        with self.assertRaisesRegex(ValueError, 'function shape'):
            overlay.suppress_logging('public enum SideSignLogging {\n}\n', 'sidesign')

    def test_preparation_never_reuses_a_nonempty_directory(self):
        marker = self.root / 'keep'
        marker.write_text('preserve')
        with self.assertRaises(FileExistsError):
            module.prepare(self.root, {'packages': {}})
        self.assertEqual(marker.read_text(), 'preserve')


if __name__ == '__main__':
    unittest.main()
