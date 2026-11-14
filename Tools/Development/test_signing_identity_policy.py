#!/usr/bin/env python3
"""Regression guard: the signing identity seam and the nested-bundle views must agree.

Two drifts are pinned here because both were found by reading call sites rather than by any
existing check, and both fail silently:

* A PKCS#12 that carries a certificate but no usable private key is not an identity. Substituting
  `Data()` for the missing key lets one travel to the signer and fail far from the import that
  caused it.
* The signed tree is described in three places — the engine that signs it, the pre-sign audit that
  judges profile coverage, and the post-sign verifier that reports what is wrong. When the lists
  disagree, a nested bundle can be signed and audited but never verified.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PKCS12 = ROOT / "Packages/SideSign/Sources/Certificates/PKCS12Parser.swift"
KEYSTORE = ROOT / "Packages/SideSign/Sources/Models/KeyStore.swift"
VERIFIER = ROOT / "App/iOS/VexSign/Utilities/Signing/SignatureVerifier.swift"
AUDIT = ROOT / "App/iOS/VexSign/Utilities/Signing/NestedBundleAudit.swift"
ENGINE = ROOT / "Packages/Vendor/Zsign/src/bundle.cpp"


def _quoted(pattern: str, source: str) -> list[str]:
    return re.findall(pattern, source)


def _engine_scope() -> tuple[set[str], set[str]]:
    """The nested code `ZBundle::GetObjectsToSign` signs, as (bundle suffixes, file suffixes).

    The function makes two separate passes over the tree: a recursive walk that collects bundles
    to sign as folders, then a flat enumeration that collects loose Mach-O files to sign in place.
    Splitting at the walk's entry point keeps the two lists from being read as one.
    """
    body = re.search(r"GetObjectsToSign.*?^\}", ENGINE.read_text(), re.DOTALL | re.MULTILINE).group(0)
    walk, _, flat = body.partition("findAllBundles(strFolder);")
    suffixes = r'IsPathSuffix\(strPath, "\.([^"]+)"\)'
    return set(_quoted(suffixes, walk)), set(_quoted(suffixes, flat))


class SigningIdentityPolicyTests(unittest.TestCase):
    def test_a_missing_private_key_is_rejected_instead_of_substituted(self) -> None:
        source = PKCS12.read_text()
        self.assertNotIn("?? Data()", source,
                         "an absent private key must not become an empty one")
        self.assertIn("guard let keyDER = parser.privateKeyDER, !keyDER.isEmpty else", source)
        self.assertIn("contains a certificate but no private key", source)
        self.assertIn("return (certDER, keyDER)", source)

    def test_a_specific_import_failure_keeps_its_own_cause(self) -> None:
        # Re-wrapping a CertificateError in another CertificateError produced
        # "PKCS#12 import failed: PKCS#12 import failed: ...", which buries the reason.
        source = PKCS12.read_text()
        self.assertIn("catch let error as CertificateError", source)
        self.assertIn("case pkcs12ImportFailed(cause: String)",
                      (ROOT / "Packages/SideSign/Sources/Models/Errors.swift").read_text())

    def test_the_only_p12_construction_path_goes_through_the_guarded_parser(self) -> None:
        source = KEYSTORE.read_text()
        self.assertIn("try PKCS12Parser.extract(p12Data, password: password)", source)
        self.assertIn("self.privateKey = result.key", source)


class NestedBundlePolicyTests(unittest.TestCase):
    def test_the_verifier_scans_every_folder_the_audit_judges_coverage_for(self) -> None:
        audited = _quoted(r'\(folder: "([^"]+)"', AUDIT.read_text())
        verified = _quoted(r'"([^"]+)"', re.search(
            r"nestedBundleFolders = \[([^\]]*)\]", VERIFIER.read_text()).group(1))
        self.assertEqual(sorted(set(audited)), ["Extensions", "PlugIns", "Watch"], audited)
        missing = sorted(set(audited) - set(verified))
        self.assertEqual(missing, [],
                         "a bundle audited before signing must also be verified after it")

    def test_the_verifier_covers_what_the_pinned_engine_actually_signs(self) -> None:
        folders, files = _engine_scope()
        # `ZBundle::GetObjectsToSign` recurses by path suffix, not by folder name, so these are the
        # engine's real views of nested code: bundles it signs as folders, and Mach-O files it
        # signs in place.
        self.assertEqual(folders, {"app", "appex", "framework", "xctest"}, folders)
        self.assertEqual(files, {"dylib"}, files)
        extensions = {e.lower() for e in _quoted(r'"([^"]+)"', re.search(
            r"nestedBundleExtensions: Set<String> = \[([^\]]*)\]", VERIFIER.read_text()).group(1))}
        # `.xctest` is deliberately not reported: a test bundle is signed by the engine but does
        # not ship, and treating it as uncovered profile-wise would start blocking IPAs that sign
        # fine today. Everything the engine signs as a bundle that *does* ship has to be visible.
        self.assertEqual(sorted(folders - {"xctest"} - extensions), [],
                         "the verifier is blind to a nested bundle the engine signs")
        # `.dylib` is signed in place as a file, not as a bundle. The verifier's nested check
        # resolves `Bundle(url:).executableURL`, which a loose dylib does not have, so listing it
        # there would report every dylib as unsigned whether or not it is. Inspecting dylibs needs
        # a Mach-O read of its own; until that exists the gap is stated here rather than papered
        # over with a list entry that would only produce false warnings.
        self.assertNotIn("dylib", extensions)

    def test_the_engine_signs_the_whole_tree_rather_than_a_fixed_folder_list(self) -> None:
        # If this ever stops being true, the folder lists above become the engine's real scope and
        # the two tests have to be rewritten against it.
        body = re.search(r"GetObjectsToSign.*?^\}", ENGINE.read_text(), re.DOTALL | re.MULTILINE).group(0)
        self.assertIn("findAllBundles(strPath)", body)
        self.assertNotIn('"Frameworks"', body)
        self.assertNotIn('"PlugIns"', body)


if __name__ == "__main__":
    unittest.main()
