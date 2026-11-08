#!/usr/bin/env python3
"""Prepare an isolated pinned SideSign/Zsign link graph; never edits app dependencies."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def run(*args, cwd=None):
    subprocess.run(list(map(str, args)), cwd=cwd, check=True)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def identity(url):
    return url.rstrip('/').rsplit('/', 1)[-1].removesuffix('.git').lower()


def rewrite_dependencies(text, known):
    pattern = r'\.package\(\s*url:\s*"([^"]+)"\s*,\s*(?:exact|from|branch|revision):\s*"[^"]+"\s*\)'
    def replace(match):
        url = match.group(1)
        name = identity(url)
        if name not in known or known[name]['repository'].removesuffix('.git').lower() != url.removesuffix('.git').lower():
            raise ValueError(f'Unreviewed source dependency: {url}')
        alias = url.rstrip('/').rsplit('/', 1)[-1].removesuffix('.git')
        return f'.package(name: "{alias}", path: "../{name}")'
    result = re.sub(pattern, replace, text)
    if re.search(r'\.package\(\s*(?:name:\s*"[^"]+",\s*)?url:', result):
        raise ValueError('Unrecognized remote source requirement; review rather than resolving it')
    return result


def library_manifest(name):
    # These packages declare duplicate test-only OpenSSL binary targets. Keep
    # their actual library Sources/dependencies, not the unrelated CLI/tests.
    dependencies = ['.package(name: "swift-crypto", path: "../swift-crypto")']
    products = ['.product(name: "Crypto", package: "swift-crypto")',
                '.product(name: "CryptoExtras", package: "swift-crypto")']
    if name == 'CodeSignKit':
        dependencies.append('.package(name: "swift-asn1", path: "../swift-asn1")')
        products.append('.product(name: "SwiftASN1", package: "swift-asn1")')
    return '''// swift-tools-version: 5.9
// Smoke-only packaging overlay; original library Sources and LICENSE retained.
import PackageDescription
let package = Package(
    name: "%s", platforms: [.iOS(.v14), .macOS(.v11)],
    products: [.library(name: "%s", targets: ["%s"])],
    dependencies: [%s],
    targets: [.target(name: "%s", dependencies: [%s], path: "Sources")]
)
''' % (name, name, name, ', '.join(dependencies), name, ', '.join(products))


def checkout(spec, destination, allow_uninitialized_submodules=False):
    if not re.fullmatch(r'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git', spec['repository']):
        raise ValueError('Unreviewed repository URL')
    if not re.fullmatch(r'[0-9a-f]{40}', spec['commit']):
        raise ValueError('Expected an immutable source commit')
    run('git', 'init', destination)
    run('git', '-C', destination, 'remote', 'add', 'origin', spec['repository'])
    run('git', '-C', destination, 'fetch', '--depth', '1', 'origin', spec['commit'])
    run('git', '-C', destination, 'checkout', '--detach', 'FETCH_HEAD')
    actual = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != spec['commit']:
        raise ValueError('Dependency checkout does not match locked revision')
    if (destination / '.gitmodules').exists() and not allow_uninitialized_submodules:
        raise ValueError('Unexpected submodules: extend and review the lock before building')


def patch_manifest(folder, expected_hash, known, original_dir, overlay=None):
    manifests = list(folder.glob('Package*.swift'))
    if {p.name for p in manifests} != {'Package.swift'}:
        raise ValueError(f'Unreviewed alternate package manifest in {folder.name}')
    path = folder / 'Package.swift'
    raw = path.read_bytes()
    if digest(raw) != expected_hash:
        raise ValueError(f'Package manifest hash mismatch: {folder.name}')
    original_dir.mkdir(parents=True, exist_ok=True)
    (original_dir / (folder.name + '.swift.txt')).write_bytes(raw)
    text = overlay if overlay is not None else rewrite_dependencies(raw.decode(), known)
    path.write_text(text)
    (folder / 'Package.resolved').unlink(missing_ok=True)
    return {'original_sha256': expected_hash, 'overlay_sha256': digest(text.encode())}


def apply_anisette_v3_overlay(deps, lock):
    specs = lock['anisette_v3_overlay']
    expected = {'Sources/Anisette/AnisetteDataManager.swift', 'Sources/Anisette/RemoteAnisetteDataProvider.swift'}
    if set(specs) != expected:
        raise ValueError('Incomplete anisette v3 source review')
    for relative, spec in specs.items():
        original = deps / 'sidesign' / relative
        source = ROOT / 'SideSign' / relative
        if digest(original.read_bytes()) != spec['upstream_sha256']:
            raise ValueError('Anisette upstream source changed: ' + relative)
        if digest(source.read_bytes()) != spec['overlay_sha256']:
            raise ValueError('Anisette overlay changed; review before building: ' + relative)
        shutil.copy2(source, original)
    return specs


def apply_privacy_overlays(deps, lock, originals):
    module_spec = importlib.util.spec_from_file_location('suppress_sdk_logging', HERE / 'patches/suppress_sdk_logging.py')
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    result = {}
    for package, spec in lock['privacy_sources'].items():
        relative = Path(spec['path'])
        if relative.is_absolute() or '..' in relative.parts or package not in ('sidesign', 'anisettekit'):
            raise ValueError('Unreviewed logging overlay path')
        path = deps / package / relative
        raw = path.read_bytes()
        if digest(raw) != spec['sha256']:
            raise ValueError('Logging source hash mismatch: ' + package)
        original = originals / package / relative
        original.parent.mkdir(parents=True, exist_ok=True)
        original.write_bytes(raw)
        patched = module.suppress_logging(raw.decode(), package).encode()
        path.write_bytes(patched)
        result[package] = {'path': spec['path'], 'original_sha256': digest(raw), 'overlay_sha256': digest(patched)}
    if set(result) != {'sidesign', 'anisettekit'}:
        raise ValueError('Both logging overlays are required')
    return result


def apply_csr_overlay(deps, lock):
    spec = lock['csr_overlay']
    if spec['path'] != 'Sources/VexSignPreparedCSR.swift':
        raise ValueError('Unreviewed CSR overlay path')
    source = HERE / 'patches/VexSignPreparedCSR.swift'
    if digest(source.read_bytes()) != spec['sha256']:
        raise ValueError('CSR overlay changed; review and update its source hash')
    expected = {'Sources/DeveloperPortal/DeveloperPortalAPI.swift', 'Sources/Constants.swift'}
    if set(spec['reviewed_sources']) != expected:
        raise ValueError('Incomplete CSR dispatcher/constants review')
    for relative, checksum in spec['reviewed_sources'].items():
        if digest((deps / 'sidesign' / relative).read_bytes()) != checksum:
            raise ValueError('CSR upstream source changed; review before building: ' + relative)
    destination = deps / 'sidesign' / spec['path']
    if destination.exists():
        raise ValueError('Refusing to overwrite an upstream CSR implementation')
    shutil.copy2(source, destination)
    return spec


def apply_registration_overlay(deps, lock):
    spec = lock['registration_overlay']
    if spec['path'] != 'Sources/VexSignRegistration.swift':
        raise ValueError('Unreviewed registration overlay path')
    source = HERE / 'patches/VexSignRegistration.swift'
    if digest(source.read_bytes()) != spec['sha256']:
        raise ValueError('Registration overlay changed; review its source hash')
    expected = {'Sources/DeveloperPortal/DeveloperPortalAPI.swift', 'Sources/Constants.swift',
                'Sources/DeveloperPortal/Devices.swift', 'Sources/DeveloperPortal/AppIDs.swift',
                'Sources/Models/Device.swift', 'Sources/Models/AppID.swift'}
    if set(spec['reviewed_sources']) != expected:
        raise ValueError('Incomplete registration wire/model review')
    for relative, checksum in spec['reviewed_sources'].items():
        if digest((deps / 'sidesign' / relative).read_bytes()) != checksum:
            raise ValueError('Registration upstream source changed: ' + relative)
    destination = deps / 'sidesign' / spec['path']
    if destination.exists():
        raise ValueError('Refusing to overwrite an upstream registration implementation')
    shutil.copy2(source, destination)
    return spec


def apply_profile_overlay(deps, lock):
    spec = lock['profile_overlay']
    if spec['path'] != 'Sources/VexSignProfiles.swift':
        raise ValueError('Unreviewed profile overlay path')
    source = HERE / 'patches/VexSignProfiles.swift'
    if digest(source.read_bytes()) != spec['sha256']:
        raise ValueError('Profile overlay changed; review its source hash')
    if spec['transport_sha256'] != lock['registration_overlay']['sha256'] or digest((deps / 'sidesign/Sources/VexSignRegistration.swift').read_bytes()) != spec['transport_sha256']:
        raise ValueError('Profile transport dependency changed')
    expected = {'Sources/DeveloperPortal/DeveloperPortalAPI.swift', 'Sources/Constants.swift',
                'Sources/DeveloperPortal/Profiles.swift', 'Sources/Models/DeveloperPortalResponses.swift',
                'Sources/Models/ProvisioningProfile.swift'}
    if set(spec['reviewed_sources']) != expected:
        raise ValueError('Incomplete profile action/model review')
    for relative, checksum in spec['reviewed_sources'].items():
        if digest((deps / 'sidesign' / relative).read_bytes()) != checksum:
            raise ValueError('Profile upstream source changed: ' + relative)
    destination = deps / 'sidesign' / spec['path']
    if destination.exists():
        raise ValueError('Refusing to overwrite an upstream profile implementation')
    shutil.copy2(source, destination)
    return spec


def apply_certificate_inventory_overlay(deps, lock):
    spec = lock['certificate_inventory_overlay']
    if spec['path'] != 'Sources/VexSignCertificateInventory.swift':
        raise ValueError('Unreviewed certificate inventory overlay path')
    source = HERE / 'patches/VexSignCertificateInventory.swift'
    if digest(source.read_bytes()) != spec['sha256']:
        raise ValueError('Certificate inventory overlay changed; review its source hash')
    if spec['transport_sha256'] != lock['registration_overlay']['sha256'] or digest((deps / 'sidesign/Sources/VexSignRegistration.swift').read_bytes()) != spec['transport_sha256']:
        raise ValueError('Certificate inventory transport dependency changed')
    expected = {'Sources/DeveloperPortal/DeveloperPortalAPI.swift', 'Sources/Constants.swift',
                'Sources/DeveloperPortal/Certificates.swift', 'Sources/Models/DeveloperPortalResponses.swift'}
    if set(spec['reviewed_sources']) != expected:
        raise ValueError('Incomplete certificate inventory wire/model review')
    for relative, checksum in spec['reviewed_sources'].items():
        if digest((deps / 'sidesign' / relative).read_bytes()) != checksum:
            raise ValueError('Certificate inventory upstream source changed: ' + relative)
    destination = deps / 'sidesign' / spec['path']
    if destination.exists():
        raise ValueError('Refusing to overwrite an upstream certificate inventory implementation')
    shutil.copy2(source, destination)
    return spec


def check_app_baseline(lock):
    manifest = json.loads((ROOT / 'Vendor/manifest.json').read_text())
    entry = next((item for item in manifest['packages'] if item['name'] == 'Zsign'), None)
    if entry is None or entry['commit'] != lock['packages']['zsign-package']['commit']:
        raise ValueError('Vendored Zsign pin changed; update/review the native smoke lock')
    package = ROOT / 'Vendor/Zsign/Package.swift'
    if not package.is_file() or digest(package.read_bytes()) != lock['packages']['zsign-package']['manifest_sha256']:
        raise ValueError('Vendored Zsign manifest changed; update/review the native smoke lock')
    resolved = json.loads((ROOT / 'VexSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
    pins = {pin['identity']: pin['state']['revision'] for pin in resolved['pins']}
    if pins.get('openssl') != lock['packages']['openssl']['commit']:
        raise ValueError('Existing app OpenSSL pin changed; update/review the native smoke lock')


def check_codec_baseline(lock):
    text = (HERE / 'Codec/SideSignSessionCodec.swift').read_text()
    match = re.search(r'sdkRevision = "([0-9a-f]{40})"', text)
    if match is None or match.group(1) != lock['sidesign']['commit']:
        raise ValueError('SDK codec revision changed; review the persistence schema before building')


def apply_der_boolean_correction(deps, lock, originals):
    spec = lock['der_boolean_correction']
    if spec['path'] != 'Sources/DEREncoder.swift':
        raise ValueError('Unreviewed DER correction path')
    source = deps / 'codesignkit' / spec['path']
    original = source.read_bytes()
    if digest(original) != spec['original_sha256']:
        raise ValueError('DER encoder source changed; review before correction')
    if original.count(b'Data([b ? 0x01 : 0x00])') != 2 or original.count(b'Data([num.boolValue ? 0x01 : 0x00])') != 1:
        raise ValueError('Unexpected DER boolean implementation')
    patched = original.replace(b'Data([b ? 0x01 : 0x00])', b'Data([b ? 0xff : 0x00])').replace(
        b'Data([num.boolValue ? 0x01 : 0x00])', b'Data([num.boolValue ? 0xff : 0x00])')
    if digest(patched) != spec['patched_sha256']:
        raise ValueError('DER correction output changed')
    destination = originals / 'codesignkit' / spec['path']
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(original)
    source.write_bytes(patched)
    return {'original_sha256': digest(original), 'patched_sha256': digest(patched)}


def install_smoke_sources(work):
    files = {
        'Signing/NativeLinkeditMetadata.swift': 'Sources/NativeSigningLinkSmoke/NativeLinkeditMetadata.swift',
        'Signing/NativeSignedArchiveAuditor.swift': 'Sources/NativeSigningLinkSmoke/NativeSignedArchiveAuditor.swift',
        'Tests/NativeLinkeditMetadataTests.swift': 'Tests/NativeSigningCodecTests/NativeLinkeditMetadataTests.swift',
        'Signing/NativeChainedFixups.swift': 'Sources/NativeSigningLinkSmoke/NativeChainedFixups.swift',
        'Tests/NativeChainedFixupsTests.swift': 'Tests/NativeSigningCodecTests/NativeChainedFixupsTests.swift',
        'Signing/NativeExportTrie.swift': 'Sources/NativeSigningLinkSmoke/NativeExportTrie.swift',
        'Tests/NativeExportTrieTests.swift': 'Tests/NativeSigningCodecTests/NativeExportTrieTests.swift',
        'Signing/NativeDyldBytecode.swift': 'Sources/NativeSigningLinkSmoke/NativeDyldBytecode.swift',
        'Tests/NativeDyldBytecodeTests.swift': 'Tests/NativeSigningCodecTests/NativeDyldBytecodeTests.swift',
        'Signing/NativeMachOLoaderPolicy.swift': 'Sources/NativeSigningLinkSmoke/NativeMachOLoaderPolicy.swift',
        'Tests/NativeMachOLoaderPolicyTests.swift': 'Tests/NativeSigningCodecTests/NativeMachOLoaderPolicyTests.swift',
        'Signing/NativeDesignatedRequirement.swift': 'Sources/NativeSigningLinkSmoke/NativeDesignatedRequirement.swift',
        'Tests/NativeDesignatedRequirementTests.swift': 'Tests/NativeSigningCodecTests/NativeDesignatedRequirementTests.swift',
        'designated-requirement-review.json': 'Reviews/designated-requirement-review.json',
        'Signing/NativeMachOMutationVerifier.swift': 'Sources/NativeSigningLinkSmoke/NativeMachOMutationVerifier.swift',
        'Tests/NativeMachOMutationTests.swift': 'Tests/NativeSigningCodecTests/NativeMachOMutationTests.swift',
        'Signing/NativeOutputEntitlements.swift': 'Sources/NativeSigningLinkSmoke/NativeOutputEntitlements.swift',
        'Signing/NativeStrictCodeResources.swift': 'Sources/NativeSigningLinkSmoke/NativeStrictCodeResources.swift',
        'Signing/NativeResourceSealVerifier.swift': 'Sources/NativeSigningLinkSmoke/NativeResourceSealVerifier.swift',
        'Signing/NativeMainSignatureConsistency.swift': 'Sources/NativeSigningLinkSmoke/NativeMainSignatureConsistency.swift',
        'Tests/NativeOutputPolicyTests.swift': 'Tests/NativeSigningCodecTests/NativeOutputPolicyTests.swift',
        'Signing/NativeDetachedCodeSignatureVerifier.swift': 'Sources/NativeSigningLinkSmoke/NativeDetachedCodeSignatureVerifier.swift',
        'Signing/NativeCodeDirectoryVerifier.swift': 'Sources/NativeSigningLinkSmoke/NativeCodeDirectoryVerifier.swift',
        'Signing/NativeStoredZIPWriter.swift': 'Sources/NativeSigningLinkSmoke/NativeStoredZIPWriter.swift',
        'Tests/NativeSignedOutputTests.swift': 'Tests/NativeSigningCodecTests/NativeSignedOutputTests.swift',
        'Smoke/Package.swift.template': 'Package.swift',
        'Smoke/LinkSmoke.swift': 'Sources/NativeSigningLinkSmoke/LinkSmoke.swift',
        'apple-cms-policy-review.json': 'Reviews/apple-cms-policy-review.json',
        'Provisioning/NativeProfileDER.swift': 'Sources/NativeSigningLinkSmoke/NativeProfileDER.swift',
        'Provisioning/NativeProfileCMSEnvelope.swift': 'Sources/NativeSigningLinkSmoke/NativeProfileCMSEnvelope.swift',
        'Provisioning/NativeAppleProfileCMSVerifier.swift': 'Sources/NativeSigningLinkSmoke/NativeAppleProfileCMSVerifier.swift',
        'Tests/NativeAppleProfileCMSTests.swift': 'Tests/NativeSigningCodecTests/NativeAppleProfileCMSTests.swift',
        # Backs the OpenSSLBuilt cases: the DER is a test resource, so it has to
        # land under the staged test target's own directory (relative to
        # Tests/NativeSigningCodecTests, hence the ../..).
        'Fixtures/cms_v1_sha256_rsa.der': 'Fixtures/cms_v1_sha256_rsa.der',
        'Provisioning/NativeProfileCertificateInventoryPolicy.swift': 'Sources/NativeSigningLinkSmoke/NativeProfileCertificateInventoryPolicy.swift',
        'Tests/NativeProfileCertificateInventoryTests.swift': 'Tests/NativeSigningCodecTests/NativeProfileCertificateInventoryTests.swift',
        'Provisioning/SideSignBoundProfilePortal.swift': 'Sources/NativeSigningLinkSmoke/SideSignBoundProfilePortal.swift',
        'Provisioning/NativeProfileResourcePolicy.swift': 'Sources/NativeSigningLinkSmoke/NativeProfileResourcePolicy.swift',
        'Tests/NativeProfileResourceTests.swift': 'Tests/NativeSigningCodecTests/NativeProfileResourceTests.swift',
        'Provisioning/SideSignProfileTransport.swift': 'Sources/NativeSigningLinkSmoke/SideSignProfileTransport.swift',
        'Tests/NativeProfileTransportTests.swift': 'Tests/NativeSigningCodecTests/NativeProfileTransportTests.swift',
        'Provisioning/NativeProfileCreation.swift': 'Sources/NativeSigningLinkSmoke/NativeProfileCreation.swift',
        'Provisioning/NativeProfileCreationExecutor.swift': 'Sources/NativeSigningLinkSmoke/NativeProfileCreationExecutor.swift',
        'Provisioning/NativeProfileReceiptStore.swift': 'Sources/NativeSigningLinkSmoke/NativeProfileReceiptStore.swift',
        'Provisioning/NativeProfileCreationKeychainStore.swift': 'Sources/NativeSigningLinkSmoke/NativeProfileCreationKeychainStore.swift',
        'Tests/NativeProfileCreationTests.swift': 'Tests/NativeSigningCodecTests/NativeProfileCreationTests.swift',
        'Provisioning/VexSignProfileTypes.swift': 'Sources/NativeSigningLinkSmoke/VexSignProfileTypes.swift',
        'Provisioning/NativeAccountProfileOperation.swift': 'Sources/NativeSigningLinkSmoke/NativeAccountProfileOperation.swift',
        'Tests/NativeAccountProfileOperationTests.swift': 'Tests/NativeSigningCodecTests/NativeAccountProfileOperationTests.swift',
        'Provisioning/NativeAccountRegistrationApproval.swift': 'Sources/NativeSigningLinkSmoke/NativeAccountRegistrationApproval.swift',
        'Provisioning/SideSignBoundRegistrationPortal.swift': 'Sources/NativeSigningLinkSmoke/SideSignBoundRegistrationPortal.swift',
        'Provisioning/SideSignRegistrationTransport.swift': 'Sources/NativeSigningLinkSmoke/SideSignRegistrationTransport.swift',
        'Tests/NativeRegistrationTransportTests.swift': 'Tests/NativeSigningCodecTests/NativeRegistrationTransportTests.swift',
        'Provisioning/NativeRegistrationExecutor.swift': 'Sources/NativeSigningLinkSmoke/NativeRegistrationExecutor.swift',
        'Provisioning/NativeRegistrationKeychainStore.swift': 'Sources/NativeSigningLinkSmoke/NativeRegistrationKeychainStore.swift',
        'Tests/NativeRegistrationExecutorTests.swift': 'Tests/NativeSigningCodecTests/NativeRegistrationExecutorTests.swift',
        'Provisioning/NativeProvisioningProfileValidator.swift': 'Sources/NativeSigningLinkSmoke/NativeProvisioningProfileValidator.swift',
        'Tests/NativeProvisioningProfileTests.swift': 'Tests/NativeSigningCodecTests/NativeProvisioningProfileTests.swift',
        'development-certificate-review.json': 'Reviews/development-certificate-review.json',
        'Identity/NativeCertificateStatusConsent.swift': 'Sources/NativeSigningLinkSmoke/NativeCertificateStatusConsent.swift',
        'Identity/NativeDevelopmentIssuerStore.swift': 'Sources/NativeSigningLinkSmoke/NativeDevelopmentIssuerStore.swift',
        'Tests/NativeCertificateStatusConsentTests.swift': 'Tests/NativeSigningCodecTests/NativeCertificateStatusConsentTests.swift',
        'Identity/NativeDevelopmentCertificatePurpose.swift': 'Sources/NativeSigningLinkSmoke/NativeDevelopmentCertificatePurpose.swift',
        'Identity/NativeDevelopmentCertificateVerifier.swift': 'Sources/NativeSigningLinkSmoke/NativeDevelopmentCertificateVerifier.swift',
        'Identity/NativeProtectedSigningHandoff.swift': 'Sources/NativeSigningLinkSmoke/NativeProtectedSigningHandoff.swift',
        'Tests/NativeDevelopmentCertificateTests.swift': 'Tests/NativeSigningCodecTests/NativeDevelopmentCertificateTests.swift',
        'Identity/NativeIPAEntryDecoder.swift': 'Sources/NativeSigningLinkSmoke/NativeIPAEntryDecoder.swift',
        'Identity/NativeIPAContentVerifier.swift': 'Sources/NativeSigningLinkSmoke/NativeIPAContentVerifier.swift',
        'Identity/NativeIPAContentInspection.swift': 'Sources/NativeSigningLinkSmoke/NativeIPAContentInspection.swift',
        'Tests/NativeIPAContentTests.swift': 'Tests/NativeSigningCodecTests/NativeIPAContentTests.swift',
        'Identity/NativeIPAArchiveIndex.swift': 'Sources/NativeSigningLinkSmoke/NativeIPAArchiveIndex.swift',
        'Identity/NativeIPAArchiveLayout.swift': 'Sources/NativeSigningLinkSmoke/NativeIPAArchiveLayout.swift',
        'Tests/NativeIPAArchiveTests.swift': 'Tests/NativeSigningCodecTests/NativeIPAArchiveTests.swift',
        'Identity/NativeMachOInspection.swift': 'Sources/NativeSigningLinkSmoke/NativeMachOInspection.swift',
        'Identity/NativeMainAppAcceptance.swift': 'Sources/NativeSigningLinkSmoke/NativeMainAppAcceptance.swift',
        'Tests/NativeMainAppAcceptanceTests.swift': 'Tests/NativeSigningCodecTests/NativeMainAppAcceptanceTests.swift',
        'Identity/NativeCertificateCreationApproval.swift': 'Sources/NativeSigningLinkSmoke/NativeCertificateCreationApproval.swift',
        'Identity/SideSignCertificateAdapter.swift': 'Sources/NativeSigningLinkSmoke/SideSignCertificateAdapter.swift',
        'Tests/NativeCertificateCreationTests.swift': 'Tests/NativeSigningCodecTests/NativeCertificateCreationTests.swift',
        'Identity/NativeSigningIdentity.swift': 'Sources/NativeSigningLinkSmoke/NativeSigningIdentity.swift',
        'Identity/NativeSigningIdentityCrypto.swift': 'Sources/NativeSigningLinkSmoke/NativeSigningIdentityCrypto.swift',
        'Identity/NativeSigningIdentityKeychainStore.swift': 'Sources/NativeSigningLinkSmoke/NativeSigningIdentityKeychainStore.swift',
        'Tests/NativeSigningIdentityTests.swift': 'Tests/NativeSigningCodecTests/NativeSigningIdentityTests.swift',
        'Authentication/NativeAccountProvisioningPlan.swift': 'Sources/NativeSigningLinkSmoke/NativeAccountProvisioningPlan.swift',
        'Authentication/SideSignProvisioningAdapter.swift': 'Sources/NativeSigningLinkSmoke/SideSignProvisioningAdapter.swift',
        'Tests/NativeProvisioningPlanTests.swift': 'Tests/NativeSigningCodecTests/NativeProvisioningPlanTests.swift',
        'Authentication/NativeAccountBackend.swift': 'Sources/NativeSigningLinkSmoke/NativeAccountBackend.swift',
        'Tests/NativeAccountBackendTests.swift': 'Tests/NativeSigningCodecTests/NativeAccountBackendTests.swift',
        'Tests/NativeV3AnisetteTests.swift': 'Tests/NativeSigningCodecTests/NativeV3AnisetteTests.swift',
        'Authentication/NativeV3AnisetteProvider.swift': 'Sources/NativeSigningLinkSmoke/NativeV3AnisetteProvider.swift',
        'Authentication/HTTPSAnisetteProvider.swift': 'Sources/NativeSigningLinkSmoke/HTTPSAnisetteProvider.swift',
        'Tests/HTTPSAnisetteProviderTests.swift': 'Tests/NativeSigningCodecTests/HTTPSAnisetteProviderTests.swift',
        'Authentication/ConsentedAnisetteProvider.swift': 'Sources/NativeSigningLinkSmoke/ConsentedAnisetteProvider.swift',
        'Authentication/SideSignAccountBridge.swift': 'Sources/NativeSigningLinkSmoke/SideSignAccountBridge.swift',
        'Tests/SideSignAccountBridgeTests.swift': 'Tests/NativeSigningCodecTests/SideSignAccountBridgeTests.swift',
        'Tests/ConsentedAnisetteProviderTests.swift': 'Tests/NativeSigningCodecTests/ConsentedAnisetteProviderTests.swift',
        'Authentication/SideSignAccountAdapter.swift': 'Sources/NativeSigningLinkSmoke/SideSignAccountAdapter.swift',
        'Authentication/SideSignTwoFactorBroker.swift': 'Sources/NativeSigningLinkSmoke/SideSignTwoFactorBroker.swift',
        'Tests/SideSignAccountAdapterTests.swift': 'Tests/NativeSigningCodecTests/SideSignAccountAdapterTests.swift',
        'Tests/SideSignTwoFactorBrokerTests.swift': 'Tests/NativeSigningCodecTests/SideSignTwoFactorBrokerTests.swift',
        'Codec/SideSignSessionCodec.swift': 'Sources/NativeSigningLinkSmoke/SideSignSessionCodec.swift',
        'Tests/SideSignSessionCodecTests.swift': 'Tests/NativeSigningCodecTests/SideSignSessionCodecTests.swift',
    }
    hashes = {}
    # Compile the app's actual lifecycle implementation, not a second model.
    for name in ['AppleAccountAuthenticationState', 'AppleAccountSessionCoordinator', 'AppleAccountSessionRepository']:
        source = ROOT / 'VexSign/Backend/Services' / (name + '.swift')
        destination = work / 'Sources/NativeSigningLinkSmoke' / source.name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        hashes[str(source.relative_to(ROOT))] = digest(destination.read_bytes())
    # Include actual platform storage byte-for-byte, not test-only substitutes.
    for name in ['AppleAccountCredentialStore', 'AppleAccountResumeJournalStore', 'AppleAccountStorageRuntimePolicy']:
        source = ROOT / 'VexSign/Security' / (name + '.swift')
        destination = work / 'Sources/NativeSigningLinkSmoke' / source.name
        shutil.copy2(source, destination)
        hashes[str(source.relative_to(ROOT))] = digest(destination.read_bytes())
    for source, target in files.items():
        destination = work / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(HERE / source, destination)
        hashes[source] = digest(destination.read_bytes())
    return hashes


def prepare(work, lock):
    # Never remove/reuse a user directory or overwrite an already prepared graph.
    for name in lock['packages']:
        if not re.fullmatch(r'[a-z0-9_-]+', name):
            raise ValueError('Invalid dependency directory name')
    work.mkdir(parents=True, exist_ok=False)
    deps = work / 'Dependencies'
    deps.mkdir()
    sources = work / 'UpstreamManifests'
    modifications = {}
    for name, spec in lock['packages'].items():
        checkout(spec, deps / name)
    side = lock['sidesign']
    checkout({'repository': 'https://github.com/' + side['repository'] + '.git', 'commit': side['commit']}, work / 'OdysseusSource', allow_uninitialized_submodules=True)
    tree = subprocess.check_output(['git', '-C', str(work / 'OdysseusSource'), 'ls-tree', '-r', 'HEAD', 'SideSign'], text=True)
    if any(line.startswith('160000') for line in tree.splitlines()):
        raise ValueError('Unexpected submodule inside the SideSign source subtree')
    shutil.copytree(work / 'OdysseusSource/SideSign', deps / 'sidesign')
    for name, spec in lock['packages'].items():
        overlay = {'codesignkit': 'CodeSignKit', 'gsacryptokit': 'GSACryptoKit'}.get(name)
        modifications[name] = patch_manifest(deps / name, spec['manifest_sha256'], lock['packages'], sources,
                                             library_manifest(overlay) if overlay else None)
    modifications['sidesign'] = patch_manifest(deps / 'sidesign', side['manifest_sha256'], lock['packages'], sources)
    # The only remaining remote-URL binary target is the original Anisette dependency.
    # SwiftPM validates its upstream checksum. Reject unreviewed binary inputs.
    allowed = {(v['url'], v['sha256']) for v in lock['binary_artifacts'].values()}
    seen = set()
    for path in deps.glob('*/Package.swift'):
        text = path.read_text()
        for url, checksum in re.findall(r'url:\s*"([^"]+)"\s*,\s*checksum:\s*"([^"]+)"', text):
            seen.add((url, checksum))
            if (url, checksum) not in allowed:
                raise ValueError('Unreviewed binary artifact')
    if seen != allowed:
        raise ValueError('The locked binary graph no longer matches the prepared manifests')
    anisette_v3_overlay = apply_anisette_v3_overlay(deps, lock)
    privacy_hashes = apply_privacy_overlays(deps, lock, work / 'UpstreamPrivacySources')
    csr_overlay = apply_csr_overlay(deps, lock)
    registration_overlay = apply_registration_overlay(deps, lock)
    profile_overlay = apply_profile_overlay(deps, lock)
    certificate_inventory_overlay = apply_certificate_inventory_overlay(deps, lock)
    der_boolean_correction = apply_der_boolean_correction(deps, lock, work / 'UpstreamSigningSources')
    first_party_hashes = install_smoke_sources(work)
    (work / 'provenance.json').write_text(json.dumps({
        'anisette_v3_overlay': anisette_v3_overlay,
        'der_boolean_correction': der_boolean_correction,
        'inputs': lock, 'manifest_overlays': modifications, 'first_party_sha256': first_party_hashes, 'privacy_overlays': privacy_hashes,
        'csr_overlay': csr_overlay, 'registration_overlay': registration_overlay, 'profile_overlay': profile_overlay, 'certificate_inventory_overlay': certificate_inventory_overlay,
        'privacy_script_sha256': digest((HERE / 'patches/suppress_sdk_logging.py').read_bytes())
    }, indent=2) + '\n')
    print(f'Prepared {work}; no Apple/account network calls were made. Native compile/link is still required.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=ROOT / '.build/native-signing-smoke')
    args = parser.parse_args()
    lock = json.loads((HERE / 'inputs.lock.json').read_text())
    check_app_baseline(lock)
    check_codec_baseline(lock)
    prepare(args.work.resolve(), lock)


if __name__ == '__main__':
    main()
