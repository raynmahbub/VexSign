#!/usr/bin/env python3
"""Independent fixture for the Apple-profile CMS parser.

Why this exists
---------------
`NativeProfileCMSEnvelope` implements a deliberately narrow CMS subset. Its own
unit tests build envelopes with the *same* hand-written DER helpers the parser
was written against, so they prove self-consistency and not much else. This
script produces an envelope with a **different implementation** — OpenSSL — and
then checks that the bytes really have the properties the parser requires:

  * CMS SignedData version 1, definite lengths only, one signer;
  * `digestAlgorithms` = SHA-256 and nothing else;
  * encapsulated content type `id-data`, attached (not detached);
  * signer identifier is issuerAndSerialNumber;
  * signed attributes sorted as DER SET OF, containing contentType id-data and
    a messageDigest equal to SHA-256(payload);
  * signatureAlgorithm rsaEncryption (or sha256WithRSAEncryption);
  * a 256..512-byte RSA PKCS#1 v1.5 signature.

That is exactly what `NativeProfileCMSEnvelope.parse` enforces, so a fixture that
passes here is a fixture the parser must accept — and the committed bytes give
the Swift tests a case they did not author.

The certificate is self-signed and ephemeral. It is **not** an Apple credential
and proves nothing about trust; `NativeAppleProfileCMSVerifier` must still reject
it (`testSyntheticCertificateCannotBecomeAppleTrustedProfile` covers that).

Usage
-----
    python3 NativeSigning/Fixtures/make_cms_fixture.py --generate
    python3 NativeSigning/Fixtures/make_cms_fixture.py --check     # no openssl
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DER_PATH = HERE / "cms_v1_sha256_rsa.der"
META_PATH = HERE / "cms_v1_sha256_rsa.json"

PAYLOAD = b"com.example.vexsign.fixture-profile-payload"

# OIDs the parser pins. Kept as raw content bytes, like the Swift constants.
OID_DATA = bytes([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 7, 1])
OID_SIGNED_DATA = bytes([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 7, 2])
OID_SHA256 = bytes([0x60, 0x86, 0x48, 1, 0x65, 3, 4, 2, 1])
OID_RSA = bytes([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 1, 1])
OID_SHA256_RSA = bytes([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 1, 0x0B])
OID_CONTENT_TYPE = bytes([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 9, 3])
OID_MESSAGE_DIGEST = bytes([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 9, 4])


# --------------------------------------------------------------------------- #
# Minimal definite-length reader (mirrors NativeProfileDER, independently)
# --------------------------------------------------------------------------- #

class Node:
    __slots__ = ("tag", "content", "encoded")

    def __init__(self, tag: int, content: bytes, encoded: bytes) -> None:
        self.tag = tag
        self.content = content
        self.encoded = encoded

    def children(self) -> list["Node"]:
        out: list[Node] = []
        offset = 0
        data = self.content
        while offset < len(data):
            node, offset = read_node(data, offset)
            out.append(node)
        return out


def read_node(data: bytes, offset: int) -> tuple[Node, int]:
    start = offset
    if offset + 2 > len(data):
        raise ValueError("truncated")
    tag = data[offset]
    offset += 1
    if tag & 0x1F == 0x1F or tag == 0:
        raise ValueError("high tag or EOC")
    first = data[offset]
    offset += 1
    if first < 128:
        length = first
    else:
        count = first & 0x7F
        if count == 0 or count > 4:
            raise ValueError("indefinite or oversized length")
        if offset + count > len(data):
            raise ValueError("truncated length")
        if data[offset] == 0:
            raise ValueError("non-minimal length")
        length = int.from_bytes(data[offset:offset + count], "big")
        offset += count
        if length < 128:
            raise ValueError("long form used for a short length")
    if length > len(data) - offset:
        raise ValueError("length past end")
    content = data[offset:offset + length]
    offset += length
    return Node(tag, content, data[start:offset]), offset


def one(data: bytes, tag: int) -> Node:
    node, end = read_node(data, 0)
    if end != len(data) or node.tag != tag:
        raise ValueError("not a single expected element")
    return node


# --------------------------------------------------------------------------- #
# Structural validation — the contract NativeProfileCMSEnvelope.parse encodes
# --------------------------------------------------------------------------- #

def validate(cms: bytes, payload: bytes) -> dict:
    if not cms or len(cms) > 1024 * 1024:
        raise ValueError("cms size")

    outer = one(cms, 0x30).children()
    if len(outer) != 2 or outer[0].tag != 6 or outer[0].content != OID_SIGNED_DATA:
        raise ValueError("not SignedData")

    explicit = outer[1].children()
    if len(explicit) != 1 or explicit[0].tag != 0x30:
        raise ValueError("bad [0] wrapper")
    body = explicit[0].children()
    if len(body) != 5:
        raise ValueError(f"SignedData needs exactly 5 children, found {len(body)}")

    version, digest_algs, encapsulated, certificates, signer_infos = body

    if version.tag != 2 or version.content != b"\x01":
        raise ValueError("SignedData version is not 1")

    algs = digest_algs.children()
    if digest_algs.tag != 0x31 or len(algs) != 1:
        raise ValueError("expected exactly one digest algorithm")
    alg_fields = algs[0].children()
    if not (1 <= len(alg_fields) <= 2) or alg_fields[0].tag != 6:
        raise ValueError("bad AlgorithmIdentifier")
    if alg_fields[0].content != OID_SHA256:
        raise ValueError("digest algorithm is not SHA-256")
    if len(alg_fields) == 2 and not (alg_fields[1].tag == 5 and not alg_fields[1].content):
        raise ValueError("unexpected algorithm parameters")

    enc = encapsulated.children()
    if not enc or enc[0].tag != 6 or enc[0].content != OID_DATA:
        raise ValueError("encapsulated content type is not id-data")
    if len(enc) != 2:
        raise ValueError("content is not attached")
    content = enc[1].children()
    if len(content) != 1 or content[0].tag != 4 or not content[0].content:
        raise ValueError("bad eContent octets")
    if content[0].content != payload:
        raise ValueError("attached payload differs from the fixture payload")

    if certificates.tag != 0xA0:
        raise ValueError("certificate set missing")
    certs = certificates.children()
    if not certs or len(certs) > 8:
        raise ValueError("certificate count out of range")
    if any(c.tag != 0x30 or len(c.encoded) > 64 * 1024 for c in certs):
        raise ValueError("bad certificate entry")
    if len({c.encoded for c in certs}) != len(certs):
        raise ValueError("duplicate certificate")

    if signer_infos.tag != 0x31:
        raise ValueError("signerInfos is not a SET")
    signers = signer_infos.children()
    if len(signers) != 1:
        raise ValueError(f"expected exactly one SignerInfo, found {len(signers)}")
    signer = signers[0].children()
    if len(signer) != 6:
        raise ValueError(f"SignerInfo needs 6 fields, found {len(signer)}")

    s_version, sid, s_digest, s_attrs, s_sig_alg, s_signature = signer
    if s_version.tag != 2 or s_version.content != b"\x01":
        raise ValueError("SignerInfo version is not 1")

    sid_fields = sid.children()
    if len(sid_fields) != 2 or sid_fields[0].tag != 0x30:
        raise ValueError("signer identifier is not issuerAndSerialNumber")
    serial = sid_fields[1].content
    if sid_fields[1].tag != 2 or not serial or len(serial) > 32:
        raise ValueError("bad serial number")
    if serial[0] & 0x80 or not any(b for b in serial):
        raise ValueError("serial is negative or zero")
    if len(serial) > 1 and serial[0] == 0 and serial[1] & 0x80 == 0:
        raise ValueError("serial has redundant leading zero")

    s_digest_fields = s_digest.children()
    if s_digest_fields[0].tag != 6 or s_digest_fields[0].content != OID_SHA256:
        raise ValueError("signer digest algorithm is not SHA-256")

    if s_attrs.tag != 0xA0:
        raise ValueError("signed attributes missing")
    attrs = s_attrs.children()
    if not attrs or len(attrs) > 16:
        raise ValueError("attribute count out of range")
    for previous, current in zip(attrs, attrs[1:]):
        if not previous.encoded < current.encoded:
            raise ValueError("signed attributes are not DER-sorted")

    seen: set[bytes] = set()
    has_content_type = False
    has_digest = False
    for attr in attrs:
        parts = attr.children()
        if len(parts) != 2 or parts[0].tag != 6 or not parts[0].content:
            raise ValueError("bad attribute shape")
        if parts[0].content in seen:
            raise ValueError("duplicate signed attribute")
        seen.add(parts[0].content)
        values = parts[1].children()
        if parts[1].tag != 0x31 or not values or len(values) > 8:
            raise ValueError("bad attribute value set")
        for previous, current in zip(values, values[1:]):
            if not previous.encoded < current.encoded:
                raise ValueError("attribute values are not DER-sorted")
        if parts[0].content == OID_CONTENT_TYPE:
            if len(values) != 1 or values[0].tag != 6 or values[0].content != OID_DATA:
                raise ValueError("contentType attribute is not id-data")
            has_content_type = True
        elif parts[0].content == OID_MESSAGE_DIGEST:
            if len(values) != 1 or values[0].tag != 4:
                raise ValueError("messageDigest attribute is not an octet string")
            if values[0].content != hashlib.sha256(payload).digest():
                raise ValueError("messageDigest does not match SHA-256(payload)")
            has_digest = True
    if not (has_content_type and has_digest):
        raise ValueError("required signed attributes are missing")

    sig_alg_fields = s_sig_alg.children()
    if not (1 <= len(sig_alg_fields) <= 2) or sig_alg_fields[0].tag != 6:
        raise ValueError("bad signature AlgorithmIdentifier")
    if sig_alg_fields[0].content not in (OID_RSA, OID_SHA256_RSA):
        raise ValueError("signature algorithm is not RSA PKCS#1 v1.5")
    if len(sig_alg_fields) == 2 and not (sig_alg_fields[1].tag == 5 and not sig_alg_fields[1].content):
        raise ValueError("unexpected signature parameters")
    if s_signature.tag != 4 or not (256 <= len(s_signature.content) <= 512):
        raise ValueError("signature length out of range")

    return {
        "cms_sha256": hashlib.sha256(cms).hexdigest(),
        "payload_sha256": hashlib.sha256(payload).hexdigest(),
        "payload_length": len(payload),
        "cms_length": len(cms),
        "certificates": len(certs),
        "signature_bytes": len(s_signature.content),
        "signed_attributes": len(attrs),
    }


# --------------------------------------------------------------------------- #
# Generation
# --------------------------------------------------------------------------- #

def generate() -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        key = work / "key.pem"
        cert = work / "cert.pem"
        payload = work / "payload.bin"
        out = work / "fixture.der"
        payload.write_bytes(PAYLOAD)

        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key), "-out", str(cert), "-days", "1",
            "-subj", "/CN=Fixture Provisioning Profile/O=VexSign Fixtures",
            "-sha256",
        ], check=True, capture_output=True)

        # Attached-content CMS with the default signed attributes (contentType,
        # signingTime, messageDigest) — a third attribute the parser must ignore
        # rather than trust.
        subprocess.run([
            "openssl", "cms", "-sign", "-binary", "-nodetach",
            "-in", str(payload), "-signer", str(cert), "-inkey", str(key),
            "-md", "sha256", "-outform", "DER", "-out", str(out),
        ], check=True, capture_output=True)

        cms = out.read_bytes()

    facts = validate(cms, PAYLOAD)
    facts.update({
        "generated_by": "openssl cms -sign -binary -nodetach -md sha256 -outform DER",
        "key": "ephemeral RSA 2048, self-signed, 1 day",
        "note": "Synthetic credential for parser testing only; never an Apple trust anchor.",
    })
    DER_PATH.write_bytes(cms)
    META_PATH.write_text(json.dumps(facts, indent=2) + "\n")
    return facts


SWIFT_TESTS = HERE.parent / "Tests/NativeAppleProfileCMSTests.swift"


def check_swift_literal(facts: dict) -> None:
    """The Swift cases carry the same bytes as a base64 literal.

    A test resource path resolves one way in `NativeSigning/Package.swift` and
    another in the flattened smoke package, so the fixture is inlined. That makes
    drift possible in a way a single source of truth is not — hence this check.
    """
    import base64
    import re

    if not SWIFT_TESTS.is_file():
        raise SystemExit(f"missing {SWIFT_TESTS}")

    match = re.search(r'fixtureCMSBase64 = """\n(.*?)\n"""', SWIFT_TESTS.read_text(), re.S)
    if not match:
        raise SystemExit("could not find the fixtureCMSBase64 literal in the Swift tests")

    decoded = base64.b64decode("".join(match.group(1).split()), validate=True)
    actual = hashlib.sha256(decoded).hexdigest()
    if actual != facts["cms_sha256"]:
        raise SystemExit(
            f"inline fixture drifted: Swift literal sha256={actual} "
            f"fixture der sha256={facts['cms_sha256']}"
        )


def check() -> dict:
    if not DER_PATH.is_file() or not META_PATH.is_file():
        raise SystemExit(f"missing fixture: {DER_PATH.name} / {META_PATH.name} (run --generate)")
    recorded = json.loads(META_PATH.read_text())
    facts = validate(DER_PATH.read_bytes(), PAYLOAD)
    for key in ("cms_sha256", "payload_sha256", "cms_length", "signature_bytes", "certificates"):
        if recorded.get(key) != facts[key]:
            raise SystemExit(f"fixture drift: {key} recorded={recorded.get(key)} actual={facts[key]}")
    check_swift_literal(facts)
    return facts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--generate", action="store_true", help="regenerate with openssl (needs openssl 3.x)")
    group.add_argument("--check", action="store_true", help="validate the committed fixture (no openssl)")
    args = parser.parse_args()

    facts = generate() if args.generate else check()
    if args.generate:
        check_swift_literal(facts)
    print(json.dumps(facts, indent=2))
    print("\nfixture conforms to the subset NativeProfileCMSEnvelope.parse accepts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
