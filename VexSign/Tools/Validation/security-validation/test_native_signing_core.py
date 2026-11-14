#!/usr/bin/env python3
"""Compile and execute credential-free regressions against the production C++ core.

Requires a C++17 compiler and OpenSSL 3 development files. Nothing is downloaded,
no Apple credentials are read, no Xcode/device result is inferred. Build products
and generated non-runnable Mach-O fixtures live in an ignored temporary directory.

  make test-signing-core
  OPENSSL_INCLUDE_DIR=/path/to/generated/openssl/include make test-signing-core
  VEXSIGN_NATIVE_SANITIZERS=1 make test-signing-core

The Objective-C++ Security bridge and Swift verifier still require the iOS tests.
"""
from __future__ import annotations

import argparse
import ctypes.util
from datetime import datetime
import os
import plistlib
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[4]
CORE = ROOT / "VexSign/Packages/Vendor/Zsign/src"
TEST = Path(__file__).resolve().parent / "native/SigningCoreRegressionTests.cpp"


def openssl_flags() -> list[str]:
    include = os.environ.get("OPENSSL_INCLUDE_DIR")
    if include:
        if not (Path(include) / "openssl/pem.h").is_file():
            raise RuntimeError("OPENSSL_INCLUDE_DIR must contain openssl/pem.h")
        flags = ["-I", include]
    else:
        flags = []
    if shutil.which("pkg-config") and not include:
        package = subprocess.run(["pkg-config", "--cflags", "--libs", "openssl"], capture_output=True, text=True)
        if package.returncode == 0:
            return shlex.split(package.stdout)
    # Some minimal Linux workspaces have the runtime library but no linker
    # symlink. Explicit sonames let a caller supply generated matching headers.
    for name in ("ssl", "crypto"):
        library = ctypes.util.find_library(name)
        flags.append("-l:" + library if sys.platform.startswith("linux") and library else "-l" + name)
    return flags


def main() -> int:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--write-public-cms-fixture", type=Path, help="explicitly regenerate public-only synthetic fixture JSON; ephemeral test key is never exported")
    options = arguments.parse_args()
    compiler = shlex.split(os.environ.get("CXX", "c++"))
    if not compiler or not shutil.which(compiler[0]):
        print("Native regressions require a C++17 compiler (set CXX).", file=sys.stderr)
        return 2
    sources = [CORE / (name + ".cpp") for name in ("archo", "bundle", "macho", "openssl", "signing")]
    sources += [CORE / "common" / (name + ".cpp") for name in ("base64", "fs", "json", "log", "sha", "timer", "util")]
    scratch = ROOT / ".build/signing-regressions"
    scratch.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="native-", dir=scratch) as temporary:
            directory = Path(temporary)
            binary = directory / "signing-core-tests"
            flags = ["-std=c++17", "-O1", "-g", "-fno-omit-frame-pointer"]
            if os.environ.get("VEXSIGN_NATIVE_SANITIZERS") == "1":
                flags += ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
            flags += shlex.split(os.environ.get("CXXFLAGS", ""))
            command = compiler + flags + ["-I", str(CORE), "-I", str(CORE / "common"), str(TEST)]
            command += [str(source) for source in sources] + openssl_flags()
            command += shlex.split(os.environ.get("LDFLAGS", "")) + ["-o", str(binary)]
            print("Compiling production native core and generated-fixture regressions…", flush=True)
            result = subprocess.run(command, cwd=ROOT, timeout=240)
            if result.returncode:
                print("Compilation failed. Install OpenSSL 3 development headers/libraries or set OPENSSL_INCLUDE_DIR/LDFLAGS.", file=sys.stderr)
                return result.returncode
            fixtures = directory / "fixtures"
            fixtures.mkdir()
            # Independent standard-library encoding/decoding catches shared
            # reader/writer mistakes that a native-only roundtrip would miss.
            reference = {"unicode": "বাংলা & 😀", "key😀": "escaped < & > \" text\n\t",
                         "false": False, "zero": 0, "real": 1.0, "negative": -1,
                         "date": datetime(2001, 1, 1), "bytes": b"\x00\xffABC",
                         "array": ["one", {"flag": True}]}
            for name, format in (("xml", plistlib.FMT_XML), ("binary", plistlib.FMT_BINARY)):
                (fixtures / ("reference-" + name + ".plist")).write_bytes(plistlib.dumps(reference, fmt=format))
            command = [str(binary), str(fixtures)]
            if options.write_public_cms_fixture:
                command.append(str(options.write_public_cms_fixture.resolve()))
            result = subprocess.run(command, cwd=directory, timeout=120)
            if result.returncode:
                return result.returncode
            roundtrip = plistlib.loads((fixtures / "native-roundtrip.bplist").read_bytes())
            if roundtrip != reference or type(roundtrip["false"]) is not bool or type(roundtrip["zero"]) is not int or type(roundtrip["real"]) is not float:
                raise RuntimeError("independent plistlib reader disagrees with the native binary writer")
            print("Independent plistlib XML/binary interoperability: PASS", flush=True)
            return 0
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("Native regressions could not complete: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
