#!/usr/bin/env python3
"""Add a prepared pitch engine to a copied D app for internal evaluation."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import sys
import tempfile
from typing import Any

import package_audio_app
import prepare_engine
import prepare_pitch_engine


PackagingError = prepare_engine.PackagingError
CODESIGN = package_audio_app.CODESIGN
PITCH_ENGINE = "PitchEngine.dengine"
MAXIMUM_MANIFEST_BYTES = 4 * 1024 * 1024
MAXIMUM_FILES = 10_000
MAXIMUM_FILE_BYTES = 512 * 1024 * 1024
MAXIMUM_AGGREGATE_BYTES = 1024 * 1024 * 1024
REQUIRED_ENGINE_FILES = (
    "python/bin/python3",
    "provider/d_pitch_analysis_backend.py",
    "provider/d_audio_access.py",
    "model-manifests/swift-f0.json",
    "python/lib/python3.12/site-packages/swift_f0/core.py",
    "python/lib/python3.12/site-packages/swift_f0/model.onnx",
)


def _checked_new_file(value: str, label: str) -> Path:
    path = prepare_engine._absolute_output(value)
    if path.name in {"", ".", ".."}:
        raise PackagingError(f"{label} must name a new regular file")
    return path


def _lexical_absolute(value: object, label: str) -> Path:
    if not isinstance(value, str) or not value or not Path(value).is_absolute():
        raise PackagingError(f"{label} must be an absolute path before report publication is enabled")
    return Path(os.path.abspath(value))


def _overlap(first: Path, second: Path) -> bool:
    return prepare_engine._is_ancestor_or_same(first, second) or prepare_engine._is_ancestor_or_same(second, first)


def _path_variants(path: Path, label: str) -> tuple[Path, ...]:
    try:
        resolved = path.resolve(strict=False)
    except (OSError, RuntimeError) as error:
        raise PackagingError(f"cannot safely resolve {label}; failure report disabled") from error
    return (path,) if resolved == path else (path, resolved)


def _prevalidate_report_and_paths(args: argparse.Namespace) -> Path:
    """Prove report isolation before any controlled failure may publish it."""
    report = _checked_new_file(args.report, "report")
    paths = {
        "app": _lexical_absolute(getattr(args, "app", None), "app"),
        "engine": _lexical_absolute(getattr(args, "engine", None), "engine"),
        "output": _lexical_absolute(getattr(args, "output", None), "output"),
        "report": report,
    }
    names = tuple(paths)
    for index, first_name in enumerate(names):
        for second_name in names[index + 1:]:
            if any(
                _overlap(first, second)
                for first in _path_variants(paths[first_name], first_name)
                for second in _path_variants(paths[second_name], second_name)
            ):
                raise PackagingError(
                    f"unsafe overlapping {first_name}/{second_name} paths; failure report disabled"
                )
    return report


def _strict_manifest_entries(engine: Path, values: object) -> dict[str, dict[str, Any]]:
    if not isinstance(values, list) or len(values) > MAXIMUM_FILES:
        raise PackagingError("pitch engine files list is missing or exceeds the finite limit")
    declarations: dict[str, dict[str, Any]] = {}
    aggregate = 0
    for entry in values:
        if not isinstance(entry, dict) or set(entry) != {"path", "sizeBytes", "sha256", "executable"}:
            raise PackagingError("pitch engine file entry has unknown, missing, or invalid fields")
        path = entry.get("path")
        size = entry.get("sizeBytes")
        digest = entry.get("sha256")
        executable = entry.get("executable")
        normalized = (
            isinstance(path, str)
            and bool(path)
            and not path.startswith("/")
            and "\x00" not in path
            and all(part not in {"", ".", ".."} for part in path.split("/"))
        )
        if (
            not normalized
            or type(size) is not int
            or size < 0
            or size > MAXIMUM_FILE_BYTES
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            or type(executable) is not bool
            or path in declarations
        ):
            raise PackagingError("pitch engine file entry has invalid type, value, digest, or path")
        if aggregate > MAXIMUM_AGGREGATE_BYTES - size:
            raise PackagingError("pitch engine declared files exceed the aggregate limit")
        aggregate += size
        declarations[path] = entry
    return declarations


def _validate_model_declaration(path: Path) -> None:
    package_audio_app._checked_regular(path, "pitch model declaration")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackagingError("pitch model declaration is unreadable or malformed") from error
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value != prepare_pitch_engine._model_declaration():
        raise PackagingError("pitch model declaration differs from the fixed internal-evaluation profile")


def _validate_pitch_engine(engine: Path) -> dict[str, Any]:
    prepare_engine._validate_tree(engine, "pitch engine")
    manifest_path = engine / "engine.json"
    try:
        info = manifest_path.lstat()
    except OSError as error:
        raise PackagingError("pitch engine manifest is missing or unreadable") from error
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAXIMUM_MANIFEST_BYTES:
        raise PackagingError("pitch engine manifest is not regular or exceeds the 4 MiB limit")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackagingError("pitch engine manifest is unreadable or malformed") from error
    exact = {
        "schemaVersion": 1,
        "kind": "d-pitch-engine",
        "pythonABI": "3.12",
        "pythonExecutable": "python/bin/python3",
        "providerScript": "provider/d_pitch_analysis_backend.py",
        "vendorDirectory": "python/lib/python3.12/site-packages/swift_f0",
        "modelManifestsDirectory": "model-manifests",
    }
    if not isinstance(manifest, dict) or type(manifest.get("schemaVersion")) is not int:
        raise PackagingError("pitch engine manifest root or schemaVersion is invalid")
    for key, expected in exact.items():
        if manifest.get(key) != expected:
            raise PackagingError(f"pitch engine manifest {key} differs from the fixed contract")
    if set(manifest) != set(exact) | {"files"}:
        raise PackagingError("pitch engine manifest contains unknown or missing fields")
    declarations = _strict_manifest_entries(engine, manifest.get("files"))
    _actual_manifest, actual = package_audio_app._manifest_files(engine)
    if declarations != actual:
        raise PackagingError("pitch engine declarations differ from actual files")
    for relative in REQUIRED_ENGINE_FILES:
        if relative not in declarations:
            raise PackagingError(f"pitch engine manifest lacks required file: {relative}")
    model_path = engine / "python/lib/python3.12/site-packages/swift_f0/model.onnx"
    prepare_pitch_engine._validate_model(model_path)
    if declarations[REQUIRED_ENGINE_FILES[-1]]["sha256"] != prepare_pitch_engine.MODEL_SHA256:
        raise PackagingError("pitch engine manifest model digest differs from the approved artifact")
    _validate_model_declaration(engine / "model-manifests/swift-f0.json")
    prepare_pitch_engine._verify_no_installation_records(engine)
    return manifest


def _write_report_exclusive(path: Path, value: dict[str, Any]) -> None:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode("utf-8") + b"\n"
    descriptor, temporary_name = tempfile.mkstemp(prefix=".d-pitch-report-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise PackagingError(f"report appeared during publication: {path}") from error
        try:
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except OSError as error:
            raise PackagingError(f"report published but directory synchronization failed: {path}: {error}") from error
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _failure_report(stage: str, error: BaseException, produced: list[str]) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "status": "failed",
        "packageKind": "d-pitch-app-internal-evaluation",
        "failedStage": stage,
        "error": str(error),
        "producedFiles": produced,
        "internalEvaluationOnly": True,
        "modelExecution": "not-run",
        "runtimeVerification": "not-run",
        "guiVerification": "not-run",
        "notarization": "not-run",
        "tccVerification": "not-run",
    }


def _package_impl(args: argparse.Namespace, state: dict[str, Any]) -> dict[str, Any]:
    state["stage"] = "validate-internal-evaluation-ack"
    if getattr(args, "internal_evaluation_ack", False) is not True:
        raise PackagingError("--internal-evaluation-ack is required")
    state["stage"] = "validate-inputs"
    app = package_audio_app._checked_directory(args.app, "app")
    if app.suffix != ".app":
        raise PackagingError("app must be an absolute .app directory")
    engine = package_audio_app._checked_directory(args.engine, "engine")
    if engine.suffix != ".dengine":
        raise PackagingError("engine must be an absolute .dengine directory")
    if re.fullmatch(r"[0-9A-Fa-f]{40}", args.identity) is None:
        raise PackagingError("identity must be an existing 40-character certificate fingerprint")
    output = prepare_engine._absolute_output(args.output)
    if output.suffix != ".app":
        raise PackagingError("output must be an absolute .app path")
    report_path: Path = state["report"]
    prepare_engine._reject_overlap(output, [app, engine])

    state["stage"] = "validate-pitch-engine"
    _validate_pitch_engine(engine)
    state["stage"] = "validate-input-app"
    package_audio_app._validate_app_tree(app)
    bundle_identifier, _info, _plist_data = package_audio_app._read_app_identity(app)
    resources = app / "Contents/Resources"
    if os.path.lexists(resources / PITCH_ENGINE):
        raise PackagingError("input app already contains a bundled pitch engine")

    state["stage"] = "verify-input-signature"
    package_audio_app._command([CODESIGN, "--verify", "--strict", str(app)], "verify input app signature")
    signed_identifier, team = package_audio_app._signature_metadata(app, "read input app signature")
    if signed_identifier != bundle_identifier:
        raise PackagingError("input signature identifier differs from CFBundleIdentifier")
    entitlements, _raw_entitlements = package_audio_app._entitlements(app, "read input app entitlements")
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise PackagingError("input app must have com.apple.security.app-sandbox=true")

    holder: Path | None = None
    copied_app: Path | None = None
    try:
        state["stage"] = "copy-input-app"
        holder = Path(tempfile.mkdtemp(prefix=".d-pitch-app-", dir=output.parent))
        copied_app = holder / output.name
        shutil.copytree(app, copied_app, symlinks=True, copy_function=shutil.copy2)
        package_audio_app._validate_app_tree(copied_app)
        copied_engine = copied_app / "Contents/Resources" / PITCH_ENGINE
        shutil.copytree(engine, copied_engine, symlinks=False, copy_function=shutil.copy2)
        _validate_pitch_engine(copied_engine)

        state["stage"] = "sign-engine-native-components"
        native_count = package_audio_app._sign_engine(copied_engine, args.identity, team)
        _validate_pitch_engine(copied_engine)

        state["stage"] = "sign-output-app"
        entitlement_file = holder / "input-entitlements.plist"
        entitlement_file.write_bytes(plistlib.dumps(entitlements, fmt=plistlib.FMT_XML, sort_keys=False))
        package_audio_app._command([
            CODESIGN, "--force", "--sign", args.identity,
            "--options", "runtime", "--timestamp=none",
            "--entitlements", str(entitlement_file), str(copied_app),
        ], "sign output app")
        entitlement_file.unlink()

        state["stage"] = "verify-output-signature"
        package_audio_app._command([CODESIGN, "--verify", "--deep", "--strict", str(copied_app)], "verify output app signature")
        final_bundle_identifier, _final_info, _final_plist = package_audio_app._read_app_identity(copied_app)
        final_identifier, final_team = package_audio_app._signature_metadata(copied_app, "read output app signature")
        final_entitlements, _final_raw = package_audio_app._entitlements(copied_app, "read output app entitlements")
        if final_bundle_identifier != bundle_identifier or final_identifier != bundle_identifier:
            raise PackagingError("output bundle or signing identifier changed")
        if final_team != team:
            raise PackagingError("output TeamIdentifier changed")
        if final_entitlements != entitlements:
            raise PackagingError("output entitlements changed")
        _validate_pitch_engine(copied_engine)

        state["stage"] = "publish-output-app"
        prepare_engine._publish_exclusive(copied_app, output)
        copied_app = None
        state["produced"].append(str(output))
        return {
            "schemaVersion": 1,
            "status": "packaged",
            "packageKind": "d-pitch-app-internal-evaluation",
            "output": str(output),
            "bundleIdentifier": bundle_identifier,
            "teamIdentifier": team,
            "engine": PITCH_ENGINE,
            "signedNativeFiles": native_count,
            "signatureVerification": "completed",
            "producedFiles": list(state["produced"]),
            "internalEvaluationOnly": True,
            "modelExecution": "not-run",
            "runtimeVerification": "not-run",
            "guiVerification": "not-run",
            "notarization": "not-run",
            "tccVerification": "not-run",
        }
    except (OSError, shutil.Error, UnicodeError) as error:
        raise PackagingError(f"{state['stage']}: {error}") from error
    finally:
        if holder is not None and holder.exists():
            shutil.rmtree(holder)


def package(args: argparse.Namespace) -> dict[str, Any]:
    # This preflight intentionally precedes the ack and semantic input checks.
    # If isolation cannot be proven, the caller receives stderr/exception only.
    report_path = _prevalidate_report_and_paths(args)
    state: dict[str, Any] = {"stage": "validate-report", "produced": [], "report": report_path}
    try:
        result = _package_impl(args, state)
    except (PackagingError, OSError, shutil.Error, UnicodeError) as error:
        failure = _failure_report(str(state["stage"]), error, list(state["produced"]))
        try:
            _write_report_exclusive(report_path, failure)
        except (PackagingError, OSError, UnicodeError) as report_error:
            raise PackagingError(
                f"{state['stage']}: {error}; failure report publication failed: {report_error}; "
                f"produced files: {state['produced']}"
            ) from error
        raise PackagingError(f"{state['stage']}: {error}; failure report: {report_path}") from error

    state["stage"] = "publish-success-report"
    try:
        _write_report_exclusive(report_path, result)
    except (PackagingError, OSError, UnicodeError) as error:
        raise PackagingError(
            f"success report publication failed after output publication; output retained at {result['output']}: {error}"
        ) from error
    return result


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--engine", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--internal-evaluation-ack", action="store_true", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        result = package(parse_arguments(sys.argv[1:] if argv is None else argv))
    except (PackagingError, OSError, shutil.Error, UnicodeError) as error:
        prepare_engine._safe_message(sys.stderr, f"package_pitch_app: {error}")
        return 2
    return 0 if prepare_engine._safe_message(sys.stdout, json.dumps(result, ensure_ascii=False, sort_keys=True)) else 2


if __name__ == "__main__":
    raise SystemExit(main())
