#!/usr/bin/env python3
"""Add one prepared video engine to a copied, re-signed D application."""

from __future__ import annotations

import argparse
import hashlib
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


AUDIO_PACKAGING = Path(__file__).resolve().parents[2] / "Audio/Packaging"
for directory in (Path(__file__).resolve().parent, AUDIO_PACKAGING):
    if str(directory) not in sys.path:
        sys.path.insert(0, str(directory))
import package_audio_app  # type: ignore[import-not-found]  # noqa: E402
import prepare_engine  # type: ignore[import-not-found]  # noqa: E402
import prepare_video_engine  # noqa: E402


PackagingError = prepare_engine.PackagingError
CODESIGN = package_audio_app.CODESIGN
VIDEO_ENGINE = "VideoEngine.dengine"
AUDIO_ENGINES = ("AudioEngine.dengine", "MRT2MusicEngine.dengine")
REQUIRED_VIDEO_FILES = (
    "python/bin/python3",
    "provider/d_video_run.py",
    "provider/d_video_model.py",
    "provider/d_video_prepare.py",
    "provider/d_audio_access.py",
    "tokenizer/special_tokens_map.json",
    "tokenizer/spiece.model",
    "tokenizer/tokenizer.json",
    "tokenizer/tokenizer_config.json",
    "model-manifests/wan21.json",
    "Vendor/wan21/__init__.py",
    "Vendor/wan21/PROVENANCE.json",
    "Vendor/wan21/LICENSE-MIT.txt",
    "Vendor/wan21/LICENSE-WAN-APACHE-2.0.txt",
)
MAXIMUM_MANIFEST_BYTES = 4 * 1024 * 1024
MAXIMUM_FILES = 10_000
MAXIMUM_FILE_BYTES = 512 * 1024 * 1024
MAXIMUM_AGGREGATE_BYTES = 1024 * 1024 * 1024


def _checked_new_file(value: str, label: str) -> Path:
    path = prepare_engine._absolute_output(value)
    if path.name in {"", ".", ".."}:
        raise PackagingError(f"{label} must name a new regular file")
    return path


def _strict_integer(value: object) -> int | None:
    return value if type(value) is int else None


def _validate_video_engine(engine: Path) -> dict[str, Any]:
    prepare_engine._validate_tree(engine, "video engine")
    manifest_path = engine / "engine.json"
    try:
        manifest_info = manifest_path.lstat()
    except OSError as error:
        raise PackagingError("video engine manifest is missing or unreadable") from error
    if not stat.S_ISREG(manifest_info.st_mode) or manifest_info.st_size > MAXIMUM_MANIFEST_BYTES:
        raise PackagingError("video engine manifest is not regular or exceeds the 4 MiB limit")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackagingError("video engine manifest is unreadable or malformed") from error
    if not isinstance(manifest, dict):
        raise PackagingError("video engine manifest root must be an object")
    exact = {
        "schemaVersion": 1,
        "kind": "d-video-engine",
        "pythonABI": "3.12",
        "pythonExecutable": "python/bin/python3",
        "providerScript": "provider/d_video_run.py",
        "vendorDirectory": "Vendor",
        "modelManifestsDirectory": "model-manifests",
    }
    for key, expected in exact.items():
        actual = manifest.get(key)
        if key == "schemaVersion":
            actual = _strict_integer(actual)
        if actual != expected:
            raise PackagingError(f"video engine manifest {key} differs from the fixed contract")
    if set(manifest) != set(exact) | {"files"}:
        raise PackagingError("video engine manifest contains unknown or missing fields")
    values = manifest.get("files")
    if not isinstance(values, list) or len(values) > MAXIMUM_FILES:
        raise PackagingError("video engine files list is missing or exceeds the limit")
    strict_declarations: dict[str, dict[str, Any]] = {}
    aggregate = 0
    for entry in values:
        if not isinstance(entry, dict) or set(entry) != {"path", "sizeBytes", "sha256", "executable"}:
            raise PackagingError("video engine file entry has unknown, missing, or invalid fields")
        path = entry["path"]
        size = entry["sizeBytes"]
        digest = entry["sha256"]
        executable = entry["executable"]
        normalized = (
            isinstance(path, str)
            and path
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
            or path in strict_declarations
        ):
            raise PackagingError("video engine file entry has invalid types, values, or path")
        if aggregate > MAXIMUM_AGGREGATE_BYTES - size:
            raise PackagingError("video engine declared files exceed the aggregate limit")
        aggregate += size
        strict_declarations[path] = entry
    declarations = strict_declarations
    package_audio_app._manifest_files(engine)
    for relative in REQUIRED_VIDEO_FILES:
        if relative not in declarations:
            raise PackagingError(f"video engine manifest lacks required file: {relative}")
    for name, digest in prepare_video_engine.TOKENIZER_DIGESTS.items():
        if declarations[f"tokenizer/{name}"].get("sha256") != digest:
            raise PackagingError(f"video engine tokenizer differs from the pinned revision: {name}")
    prepare_video_engine._validate_model_declaration(engine / "model-manifests/wan21.json")
    return manifest


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _audio_snapshots(resources: Path) -> dict[str, dict[str, tuple[int, int, str]]]:
    result: dict[str, dict[str, tuple[int, int, str]]] = {}
    for name in AUDIO_ENGINES:
        engine = resources / name
        if not os.path.lexists(engine):
            continue
        if engine.is_symlink() or not engine.is_dir():
            raise PackagingError(f"existing audio engine must be a regular directory: {name}")
        prepare_engine._validate_tree(engine, f"existing audio engine {name}")
        files: dict[str, tuple[int, int, str]] = {}
        for current, _directories, names in os.walk(engine, followlinks=False):
            for filename in names:
                path = Path(current) / filename
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode):
                    raise PackagingError(f"existing audio engine contains a non-regular file: {path}")
                files[path.relative_to(engine).as_posix()] = (
                    stat.S_IMODE(info.st_mode), info.st_size, _sha256(path),
                )
        result[name] = files
    return result


def _write_report_exclusive(path: Path, value: dict[str, Any]) -> None:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode("utf-8") + b"\n"
    descriptor, temporary_name = tempfile.mkstemp(prefix=".d-video-report-", dir=path.parent)
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


def package(args: argparse.Namespace) -> dict[str, Any]:
    app = package_audio_app._checked_directory(args.app, "app")
    if app.suffix != ".app":
        raise PackagingError("app must be an absolute .app directory")
    engine = package_audio_app._checked_directory(args.engine, "engine")
    if engine.suffix != ".dengine":
        raise PackagingError("engine must be an absolute .dengine directory")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", args.identity):
        raise PackagingError("identity must be an existing 40-character certificate fingerprint")
    output = prepare_engine._absolute_output(args.output)
    if output.suffix != ".app":
        raise PackagingError("output must be an absolute .app path")
    report_path = _checked_new_file(args.report, "report")
    if report_path == output:
        raise PackagingError("report and output must be distinct")
    prepare_engine._reject_overlap(output, [app, engine])
    if prepare_engine._is_ancestor_or_same(app, report_path) or prepare_engine._is_ancestor_or_same(engine, report_path):
        raise PackagingError("report overlaps an input root")

    _validate_video_engine(engine)
    package_audio_app._validate_app_tree(app)
    bundle_identifier, _info, _plist_data = package_audio_app._read_app_identity(app)
    resources = app / "Contents/Resources"
    if os.path.lexists(resources / VIDEO_ENGINE):
        raise PackagingError("input app already contains a bundled video engine")
    audio_before = _audio_snapshots(resources)

    package_audio_app._command([CODESIGN, "--verify", "--strict", str(app)], "verify input app signature")
    signed_identifier, team = package_audio_app._signature_metadata(app, "read input app signature")
    if signed_identifier != bundle_identifier:
        raise PackagingError("input signature identifier differs from CFBundleIdentifier")
    entitlements, _raw_entitlements = package_audio_app._entitlements(app, "read input app entitlements")
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise PackagingError("input app must have com.apple.security.app-sandbox=true")

    holder: Path | None = None
    copied_app: Path | None = None
    published = False
    try:
        holder = Path(tempfile.mkdtemp(prefix=".d-video-app-", dir=output.parent))
        copied_app = holder / output.name
        shutil.copytree(app, copied_app, symlinks=True, copy_function=shutil.copy2)
        package_audio_app._validate_app_tree(copied_app)
        copied_resources = copied_app / "Contents/Resources"
        copied_engine = copied_resources / VIDEO_ENGINE
        shutil.copytree(engine, copied_engine, symlinks=False, copy_function=shutil.copy2)
        _validate_video_engine(copied_engine)

        native_count = package_audio_app._sign_engine(copied_engine, args.identity, team)
        _validate_video_engine(copied_engine)
        if _audio_snapshots(copied_resources) != audio_before:
            raise PackagingError("existing bundled audio engine bytes or modes changed")

        entitlement_file = holder / "input-entitlements.plist"
        entitlement_file.write_bytes(plistlib.dumps(entitlements, fmt=plistlib.FMT_XML, sort_keys=False))
        package_audio_app._command([
            CODESIGN, "--force", "--sign", args.identity,
            "--options", "runtime", "--timestamp=none",
            "--entitlements", str(entitlement_file), str(copied_app),
        ], "sign output app")
        entitlement_file.unlink()

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
        _validate_video_engine(copied_engine)
        if _audio_snapshots(copied_resources) != audio_before:
            raise PackagingError("existing bundled audio engine bytes or modes changed")

        result = {
            "status": "packaged",
            "output": str(output),
            "bundleIdentifier": bundle_identifier,
            "teamIdentifier": team,
            "engine": VIDEO_ENGINE,
            "preservedAudioEngines": sorted(audio_before),
            "signedNativeFiles": native_count,
            "runtimeVerification": "not-run",
        }
        prepare_engine._publish_exclusive(copied_app, output)
        copied_app = None
        published = True
        try:
            _write_report_exclusive(report_path, result)
        except (PackagingError, OSError, UnicodeError) as error:
            raise PackagingError(
                f"report publication failed after output publication; packaged App retained at {output}: {error}"
            ) from error
        return result
    except (OSError, shutil.Error, UnicodeError) as error:
        suffix = " after output publication" if published else ""
        raise PackagingError(f"package video app{suffix}: {error}") from error
    finally:
        if holder is not None and holder.exists():
            shutil.rmtree(holder)


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--engine", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--report", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        result = package(parse_arguments(sys.argv[1:] if argv is None else argv))
    except (PackagingError, OSError, shutil.Error, UnicodeError) as error:
        prepare_engine._safe_message(sys.stderr, f"package_video_app: {error}")
        return 2
    if not prepare_engine._safe_message(sys.stdout, json.dumps(result, ensure_ascii=False, sort_keys=True)):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
