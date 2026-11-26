from __future__ import annotations

import json
import os
import platform
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from typing import Callable, Mapping, Sequence


SUPPORTED_ARCHITECTURES = {"arm64", "arm64e", "aarch64"}
MIN_BOOTSTRAP_IOS = (27, 0, 0)
LEGACY_PAIRING_IOS_MIN = (17, 4, 0)
LEGACY_REMOTE_REQUIRED_IOS_MIN = (26, 4, 0)


class BootstrapEnvironmentError(RuntimeError):
    pass


@dataclass(frozen=True)
class OSVersion:
    major: int
    minor: int
    patch: int = 0

    @classmethod
    def parse(cls, raw: str) -> "OSVersion":
        parts = raw.strip().split(".")
        if len(parts) not in (2, 3) or any(not p.isdigit() for p in parts):
            raise BootstrapEnvironmentError(f"Invalid OS version: {raw!r}")
        nums = [int(p) for p in parts]
        if any(n < 0 or n > 999 for n in nums):
            raise BootstrapEnvironmentError(f"Invalid OS version: {raw!r}")
        return cls(nums[0], nums[1], nums[2] if len(nums) == 3 else 0)

    def __lt__(self, other: "OSVersion") -> bool:
        return (self.major, self.minor, self.patch) < (other.major, other.minor, other.patch)

    def __ge__(self, other: "OSVersion") -> bool:
        return not self < other

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


@dataclass(frozen=True)
class EnvironmentReport:
    os_name: str
    os_version: OSVersion | None
    architecture: str
    is_ios: bool
    is_supported_bootstrap: bool
    is_legacy_pairing_supported: bool
    developer_mode: bool | None
    localdevvpn_reachable: bool | None
    helper_apps: Mapping[str, bool]
    issues: Sequence[str] = field(default_factory=tuple)

    @property
    def ok(self) -> bool:
        return not self.issues


def detect_architecture(machine: str | None = None) -> str:
    arch = (machine or platform.machine() or "").strip().lower()
    if arch in {"aarch64", "arm64"}:
        return "arm64"
    if arch == "arm64e":
        return "arm64e"
    return arch or "unknown"


def validate_architecture(arch: str) -> None:
    if arch not in SUPPORTED_ARCHITECTURES:
        raise BootstrapEnvironmentError(f"Unsupported architecture: {arch}")


def detect_ios_version(env: Mapping[str, str] | None = None, sw_vers: Callable[[], str] | None = None) -> OSVersion | None:
    env = env or os.environ
    for key in ("VEXSIGN_IOS_VERSION", "OS_VERSION"):
        value = env.get(key)
        if value:
            return OSVersion.parse(value)
    if sw_vers is not None:
        out = sw_vers().strip()
        m = re.search(r"ProductVersion:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?)", out)
        if m:
            return OSVersion.parse(m.group(1))
    return None


def is_supported_bootstrap_version(version: OSVersion | None) -> bool:
    return version is not None and version >= OSVersion(*MIN_BOOTSTRAP_IOS)


def is_legacy_pairing_supported(version: OSVersion | None) -> bool:
    return version is not None and version >= OSVersion(*LEGACY_PAIRING_IOS_MIN) and version < OSVersion(*MIN_BOOTSTRAP_IOS)


def check_localdevvpn(peer: str = "10.7.0.1", timeout_s: float = 0.5, connect: Callable[[str, int, float], bool] | None = None) -> bool:
    if connect is not None:
        return bool(connect(peer, 62078, timeout_s))
    import socket

    try:
        with socket.create_connection((peer, 62078), timeout=timeout_s):
            return True
    except Exception:
        return False


def check_helper_apps(names: Sequence[str], which: Callable[[str], str | None] = shutil.which) -> dict[str, bool]:
    return {name: which(name) is not None for name in names}


def collect_environment(
    *,
    env: Mapping[str, str] | None = None,
    machine: str | None = None,
    os_name: str | None = None,
    sw_vers: Callable[[], str] | None = None,
    helper_names: Sequence[str] = (),
    localdevvpn_peer: str = "10.7.0.1",
    localdevvpn_connect: Callable[[str, int, float], bool] | None = None,
    developer_mode: bool | None = None,
) -> EnvironmentReport:
    env = env or os.environ
    arch = detect_architecture(machine)
    os_name = (os_name or platform.system() or "unknown").strip()
    version = detect_ios_version(env, sw_vers)
    is_ios = os_name.lower() in {"ios", "iphoneos", "darwin"} and (env.get("VEXSIGN_IOS_VERSION") or env.get("OS_VERSION") or os_name.lower() != "darwin")
    if env.get("VEXSIGN_IOS_VERSION") or env.get("OS_VERSION"):
        is_ios = True
    supported = is_supported_bootstrap_version(version)
    legacy = is_legacy_pairing_supported(version)
    helpers = check_helper_apps(helper_names)
    vpn = check_localdevvpn(localdevvpn_peer, connect=localdevvpn_connect) if env.get("VEXSIGN_CHECK_VPN", "0") == "1" else None
    issues: list[str] = []
    try:
        validate_architecture(arch)
    except BootstrapEnvironmentError as e:
        issues.append(str(e))
    if version is None:
        issues.append("Unable to determine iOS version")
    elif not (supported or legacy):
        issues.append(f"Unsupported iOS version for bootstrap: {version}")
    for name, ok in helpers.items():
        if not ok:
            issues.append(f"Missing required helper: {name}")
    if vpn is False:
        issues.append("LocalDevVPN peer is not reachable")
    if developer_mode is False:
        issues.append("Developer Mode is not enabled")
    return EnvironmentReport(
        os_name=os_name,
        os_version=version,
        architecture=arch,
        is_ios=is_ios,
        is_supported_bootstrap=supported,
        is_legacy_pairing_supported=legacy,
        developer_mode=developer_mode,
        localdevvpn_reachable=vpn,
        helper_apps=helpers,
        issues=tuple(issues),
    )


def report_json(report: EnvironmentReport) -> str:
    return json.dumps(
        {
            "os_name": report.os_name,
            "os_version": str(report.os_version) if report.os_version else None,
            "architecture": report.architecture,
            "is_ios": report.is_ios,
            "is_supported_bootstrap": report.is_supported_bootstrap,
            "is_legacy_pairing_supported": report.is_legacy_pairing_supported,
            "developer_mode": report.developer_mode,
            "localdevvpn_reachable": report.localdevvpn_reachable,
            "helper_apps": dict(report.helper_apps),
            "issues": list(report.issues),
            "ok": report.ok,
        },
        indent=2,
        sort_keys=True,
    )
