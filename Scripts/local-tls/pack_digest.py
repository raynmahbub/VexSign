#!/usr/bin/env python3
"""Digest of a local-TLS identity, shared by the build and the app.

The identity is the three files the local install server reads:
`server.pem`, `server.crt` and `commonName.txt`. The digest is SHA-256 over them
in that order, each trimmed of surrounding whitespace and joined with a single
newline:

    sha256( pem.strip() + "\\n" + crt.strip() + "\\n" + cn.strip() )

Keeping the rule this small is deliberate: `VexSign/Backend/Server/LocalTLSIdentity.swift`
computes the same value in the app, and `VexSignTests/LocalTLSIdentityTests.swift`
holds both to it.

Usage:
    pack_digest.py <directory>        # prints the lowercase hex digest
    pack_digest.py --verify <dir> <hex>
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

FILES = ("server.pem", "server.crt", "commonName.txt")


def read_identity(directory: Path) -> list[str]:
    missing = [name for name in FILES if not (directory / name).is_file()]
    if missing:
        raise SystemExit(f"missing identity file(s) in {directory}: {', '.join(missing)}")
    return [(directory / name).read_text(encoding="utf-8", errors="strict").strip() for name in FILES]


def digest(directory: Path) -> str:
    joined = "\n".join(read_identity(directory))
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "--verify":
        if len(argv) != 4:
            raise SystemExit("usage: pack_digest.py --verify <directory> <expected-hex>")
        actual = digest(Path(argv[2]))
        expected = argv[3].strip().lower().removeprefix("sha256:")
        if actual != expected:
            print(
                f"error: TLS identity digest mismatch\n"
                f"  expected: sha256:{expected}\n"
                f"  actual  : sha256:{actual}\n"
                f"Refusing to build with an identity that is not the pinned one.",
                file=sys.stderr,
            )
            return 1
        print(f"TLS identity digest verified: sha256:{actual}")
        return 0

    if len(argv) != 2:
        raise SystemExit("usage: pack_digest.py <directory>")
    print(digest(Path(argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
