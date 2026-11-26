from __future__ import annotations

import argparse
import json
import os
import shutil
import tempfile
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Callable, Optional

from .environment import EnvironmentReport, collect_environment
from .integrity import IntegrityError, load_manifest, verify_artifact
from .ipa import IPAInspection, IPAValidationError, inspect_ipa


class BootstrapState(str, Enum):
    PENDING = "pending"
    ENVIRONMENT_CHECK = "environment_check"
    PAIRING_PREPARATION = "pairing_preparation"
    PAIRING_COMPLETE = "pairing_complete"
    PAIRING_VERIFIED = "pairing_verified"
    AUTHENTICATED = "authenticated"
    PROVISIONED = "provisioned"
    IPA_VALIDATED = "ipa_validated"
    SIGNED = "signed"
    SIGNATURE_VERIFIED = "signature_verified"
    INSTALL_SUBMITTED = "install_submitted"
    INSTALL_CONFIRMED = "install_confirmed"
    LAUNCH_VERIFIED = "launch_verified"
    FAILED = "failed"
    CANCELLED = "cancelled"


TERMINAL_STATES = {BootstrapState.INSTALL_CONFIRMED, BootstrapState.LAUNCH_VERIFIED, BootstrapState.FAILED, BootstrapState.CANCELLED}


@dataclass
class BootstrapContext:
    work_dir: Path
    manifest_path: Optional[Path] = None
    ipa_path: Optional[Path] = None
    expected_bundle_id: Optional[str] = None
    expected_version: Optional[str] = None
    state: BootstrapState = BootstrapState.PENDING
    report: Optional[EnvironmentReport] = None
    ipa_inspection: Optional[IPAInspection] = None
    errors: list[str] = field(default_factory=list)
    cleaned_up: bool = False

    def fail(self, message: str) -> "BootstrapContext":
        self.state = BootstrapState.FAILED
        self.errors.append(message)
        return self

    def cancel(self) -> "BootstrapContext":
        self.state = BootstrapState.CANCELLED
        return self


@dataclass
class BootstrapAdapters:
    """Platform adapters. Real implementations are provided by the on-device runtime.
    Tests inject fakes to exercise state transitions and validation."""
    prepare_pairing: Callable[[BootstrapContext], None] = lambda ctx: (_ for _ in ()).throw(NotImplementedError("pairing preparation adapter not configured"))
    complete_pairing: Callable[[BootstrapContext], None] = lambda ctx: (_ for _ in ()).throw(NotImplementedError("pairing completion adapter not configured"))
    verify_pairing: Callable[[BootstrapContext], None] = lambda ctx: (_ for _ in ()).throw(NotImplementedError("pairing verification adapter not configured"))
    authenticate: Callable[[BootstrapContext], None] = lambda ctx: (_ for _ in ()).throw(NotImplementedError("authentication adapter not configured"))
    provision: Callable[[BootstrapContext], None] = lambda ctx: (_ for _ in ()).throw(NotImplementedError("provisioning adapter not configured"))
    sign: Callable[[BootstrapContext], None] = lambda ctx: (_ for _ in ()).throw(NotImplementedError("signing adapter not configured"))
    verify_signature: Callable[[BootstrapContext], None] = lambda ctx: (_ for _ in ()).throw(NotImplementedError("signature verification adapter not configured"))
    install: Callable[[BootstrapContext], None] = lambda ctx: (_ for _ in ()).throw(NotImplementedError("installation adapter not configured"))
    confirm_install: Callable[[BootstrapContext], None] = lambda ctx: (_ for _ in ()).throw(NotImplementedError("install confirmation adapter not configured"))
    verify_launch: Callable[[BootstrapContext], None] = lambda ctx: (_ for _ in ()).throw(NotImplementedError("launch verification adapter not configured"))


class BootstrapCancelled(Exception):
    pass


def _check_cancel(cancelled: Callable[[], bool] | None) -> None:
    if cancelled and cancelled():
        raise BootstrapCancelled()


def run_bootstrap(
    ctx: BootstrapContext,
    adapters: BootstrapAdapters,
    *,
    cancelled: Callable[[], bool] | None = None,
    env_kwargs: dict | None = None,
) -> BootstrapContext:
    try:
        _check_cancel(cancelled)
        ctx.state = BootstrapState.ENVIRONMENT_CHECK
        ctx.report = collect_environment(**(env_kwargs or {}))
        if not ctx.report.ok:
            return ctx.fail("; ".join(ctx.report.issues))

        if ctx.manifest_path:
            manifest = load_manifest(ctx.manifest_path)
            for artifact in manifest.get("artifacts", []):
                name = artifact.get("name")
                if not isinstance(name, str):
                    continue
                artifact_path = ctx.work_dir / name
                if artifact_path.exists():
                    verify_artifact(artifact_path, artifact)

        _check_cancel(cancelled)
        ctx.state = BootstrapState.PAIRING_PREPARATION
        adapters.prepare_pairing(ctx)
        _check_cancel(cancelled)
        ctx.state = BootstrapState.PAIRING_COMPLETE
        adapters.complete_pairing(ctx)
        _check_cancel(cancelled)
        ctx.state = BootstrapState.PAIRING_VERIFIED
        adapters.verify_pairing(ctx)

        _check_cancel(cancelled)
        adapters.authenticate(ctx)
        ctx.state = BootstrapState.AUTHENTICATED

        _check_cancel(cancelled)
        adapters.provision(ctx)
        ctx.state = BootstrapState.PROVISIONED

        _check_cancel(cancelled)
        if ctx.ipa_path:
            ctx.ipa_inspection = inspect_ipa(ctx.ipa_path, expected_bundle_id=ctx.expected_bundle_id)
            if ctx.expected_version and ctx.ipa_inspection.version != ctx.expected_version:
                return ctx.fail(f"Unexpected IPA version: {ctx.ipa_inspection.version}")
        ctx.state = BootstrapState.IPA_VALIDATED

        _check_cancel(cancelled)
        adapters.sign(ctx)
        ctx.state = BootstrapState.SIGNED

        _check_cancel(cancelled)
        adapters.verify_signature(ctx)
        ctx.state = BootstrapState.SIGNATURE_VERIFIED

        _check_cancel(cancelled)
        adapters.install(ctx)
        ctx.state = BootstrapState.INSTALL_SUBMITTED

        _check_cancel(cancelled)
        adapters.confirm_install(ctx)
        ctx.state = BootstrapState.INSTALL_CONFIRMED

        _check_cancel(cancelled)
        adapters.verify_launch(ctx)
        ctx.state = BootstrapState.LAUNCH_VERIFIED
        return ctx
    except BootstrapCancelled:
        ctx.cancel()
        return ctx
    except (IntegrityError, IPAValidationError) as e:
        return ctx.fail(str(e))
    except NotImplementedError as e:
        return ctx.fail(str(e))
    except Exception as e:
        return ctx.fail(f"Unexpected bootstrap failure: {e}")
    finally:
        cleanup(ctx)


def cleanup(ctx: BootstrapContext) -> None:
    if ctx.cleaned_up:
        return
    work = ctx.work_dir
    try:
        if work.exists() and work.is_dir():
            # only remove files we created inside work_dir; keep the dir itself for logs if desired
            for child in work.iterdir():
                if child.name.startswith(".vexsign-tmp-"):
                    if child.is_dir() and not child.is_symlink():
                        shutil.rmtree(child, ignore_errors=True)
                    else:
                        try:
                            child.unlink()
                        except Exception:
                            pass
    finally:
        ctx.cleaned_up = True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="VexSign bootstrap orchestrator")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--bundle-id", dest="bundle_id")
    parser.add_argument("--version", dest="version")
    parser.add_argument("--work-dir", type=Path, default=Path(".vexsign-bootstrap"))
    parser.add_argument("--check-environment", action="store_true")
    args = parser.parse_args(argv)

    args.work_dir.mkdir(parents=True, exist_ok=True)
    ctx = BootstrapContext(work_dir=args.work_dir, manifest_path=args.manifest, ipa_path=args.ipa,
                           expected_bundle_id=args.bundle_id, expected_version=args.version)
    if args.check_environment:
        ctx.state = BootstrapState.ENVIRONMENT_CHECK
        ctx.report = collect_environment()
        print(json.dumps({"state": ctx.state.value, "ok": ctx.report.ok, "issues": list(ctx.report.issues)}, indent=2))
        return 0 if ctx.report.ok else 2

    adapters = BootstrapAdapters()
    result = run_bootstrap(ctx, adapters)
    print(json.dumps({"state": result.state.value, "errors": result.errors, "cleaned_up": result.cleaned_up}, indent=2))
    return 0 if result.state in {BootstrapState.INSTALL_CONFIRMED, BootstrapState.LAUNCH_VERIFIED} else 1


if __name__ == "__main__":
    raise SystemExit(main())
