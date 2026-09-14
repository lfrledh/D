#!/usr/bin/env python3
"""Prepare the fixed SwiftF0 engine for approved internal evaluation only."""

from __future__ import annotations

import argparse
from email.parser import Parser
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

import prepare_engine


PackagingError = prepare_engine.PackagingError
MODEL_SHA256 = "fa91bb45512b90339cf4b00a599ba8fe3a253c46419fcfe6b46df77a8a8336a5"
MODEL_SIZE_BYTES = 399_114
INSTALLATION_RECORDS = frozenset({"INSTALLER", "RECORD", "REQUESTED", "direct_url.json"})
PROVIDERS = ("d_pitch_analysis_backend.py", "d_audio_access.py")
DISTRIBUTIONS = {
    "swift-f0": "0.1.2",
    "onnxruntime": "1.22.1",
    "numpy": "2.4.3",
    "coloredlogs": "15.0.1",
    "humanfriendly": "10.0",
    "flatbuffers": "25.12.19",
    "packaging": "26.3",
    "protobuf": "7.36.1",
    "sympy": "1.14.0",
    "mpmath": "1.3.0",
}
PACKAGE_DIRECTORIES = (
    "swift_f0",
    "onnxruntime",
    "numpy",
    "coloredlogs",
    "humanfriendly",
    "flatbuffers",
    "packaging",
    "sympy",
    "mpmath",
)
OPTIONAL_NATIVE_DIRECTORIES = ("numpy.libs", "onnxruntime.libs")
MAXIMUM_LICENSE_BYTES = 4 * 1024 * 1024
DISTRIBUTION_PACKAGE_PATHS = {
    "swift-f0": ("swift_f0",),
    "onnxruntime": ("onnxruntime",),
    "numpy": ("numpy", "numpy.libs"),
    "coloredlogs": ("coloredlogs",),
    "humanfriendly": ("humanfriendly",),
    "flatbuffers": ("flatbuffers",),
    "packaging": ("packaging",),
    "protobuf": ("google/protobuf", "google/_upb"),
    "sympy": ("sympy",),
    "mpmath": ("mpmath",),
}


def _canonical_distribution_name(value: str) -> str:
    return value.strip().lower().replace("_", "-").replace(".", "-")


def _regular(path: Path, label: str) -> os.stat_result:
    try:
        info = path.lstat()
    except OSError as error:
        raise PackagingError(f"{label} is missing or unreadable: {path}") from error
    if not stat.S_ISREG(info.st_mode):
        raise PackagingError(f"{label} must be a regular file: {path}")
    return info


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _looks_like_license_material(path: Path) -> bool:
    lowered = path.name.lower()
    stem_matches = lowered in {"license", "copying", "notice"} or lowered.startswith(
        ("license.", "copying.", "notice.")
    )
    if not stem_matches:
        return False
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size < 32 or info.st_size > MAXIMUM_LICENSE_BYTES:
            return False
        with path.open("rb") as handle:
            sample = handle.read(min(info.st_size, 4096))
    except OSError:
        return False
    return bool(sample.strip())


def _license_material(site: Path, distribution: Path, name: str) -> tuple[Path, ...]:
    roots = [distribution]
    for relative in DISTRIBUTION_PACKAGE_PATHS[name]:
        candidate = site / relative
        if candidate.is_dir() and not candidate.is_symlink():
            roots.append(candidate)
    result = tuple(
        path
        for root in roots
        for path in root.rglob("*")
        if _looks_like_license_material(path)
    )
    if not result:
        raise PackagingError(
            f"installed distribution lacks actual LICENSE/COPYING/NOTICE material: {name}"
        )
    return result


def _distribution(site: Path, name: str, version: str) -> Path:
    directory = site / f"{name.replace('-', '_')}-{version}.dist-info"
    if directory.is_symlink() or not directory.is_dir():
        raise PackagingError(f"fixed distribution missing: {name} {version}")
    prepare_engine._validate_tree(directory, f"distribution {name}")
    metadata_path = directory / "METADATA"
    _regular(metadata_path, f"distribution metadata for {name}")
    try:
        metadata = Parser().parsestr(metadata_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as error:
        raise PackagingError(f"distribution metadata is unreadable: {name}") from error
    actual_name = _canonical_distribution_name(metadata.get("Name", ""))
    if actual_name != _canonical_distribution_name(name) or metadata.get("Version") != version:
        raise PackagingError(f"distribution identity mismatch: {name} {version}")
    # A metadata License header is not distributable attribution material.
    # Require a real installed text file that is already inside one of the
    # selected package/dist-info roots, so the normal copy preserves it.
    _license_material(site, directory, name)
    return directory


def _selected_site_entries(site: Path) -> list[tuple[Path, Path]]:
    selected: list[tuple[Path, Path]] = []
    for name in PACKAGE_DIRECTORIES:
        source = site / name
        if source.is_symlink() or not source.is_dir():
            raise PackagingError(f"required package missing or unsafe: {name}")
        prepare_engine._validate_tree(source, f"package {name}")
        selected.append((source, Path(name)))

    google = site / "google"
    if google.is_symlink() or not google.is_dir():
        raise PackagingError("required protobuf namespace package is missing or unsafe")
    for name in ("protobuf", "_upb"):
        source = google / name
        if source.is_symlink() or not source.is_dir():
            raise PackagingError(f"required protobuf component missing or unsafe: google/{name}")
        prepare_engine._validate_tree(source, f"protobuf component google/{name}")
        selected.append((source, Path("google") / name))

    for name in OPTIONAL_NATIVE_DIRECTORIES:
        source = site / name
        if prepare_engine._lexists(source):
            if source.is_symlink() or not source.is_dir():
                raise PackagingError(f"optional native directory is unsafe: {name}")
            prepare_engine._validate_tree(source, f"native directory {name}")
            selected.append((source, Path(name)))

    for name, version in DISTRIBUTIONS.items():
        source = _distribution(site, name, version)
        selected.append((source, Path(source.name)))
    return selected


def _copy_selected_site(site: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    for source, relative in _selected_site_entries(site):
        target = destination / relative
        if prepare_engine._lexists(target):
            raise PackagingError(f"duplicate selected site-packages entry: {relative.as_posix()}")
        prepare_engine._copy_tree(source, target)
        if relative.name.endswith(".dist-info"):
            for name in INSTALLATION_RECORDS:
                record = target / name
                if record.is_file():
                    record.unlink()


def _copy_runtime(python_root: Path, site: Path, target: Path) -> None:
    interpreter = python_root / "bin/python3.12"
    stdlib = python_root / "lib/python3.12"
    prepare_engine._reject_symlink_ancestors(interpreter.parent, "python interpreter")
    prepare_engine._reject_symlink_ancestors(stdlib, "python standard library")
    _regular(interpreter, "python-root bin/python3.12")
    if stdlib.is_symlink() or not stdlib.is_dir():
        raise PackagingError("python-root must contain regular lib/python3.12")
    _regular(stdlib / "LICENSE.txt", "Python license")
    _regular(stdlib / "encodings/__init__.py", "Python encodings package")
    prepare_engine._validate_tree(stdlib, "Python standard library", skip=True)

    (target / "bin").mkdir(parents=True, exist_ok=False)
    shutil.copy2(interpreter, target / "bin/python3")
    prepare_engine._copy_tree(stdlib, target / "lib/python3.12", exclude_site_packages=True)
    _copy_selected_site(site, target / "lib/python3.12/site-packages")


def _copy_providers(provider: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    for name in PROVIDERS:
        source = provider / name
        _regular(source, f"provider {name}")
        shutil.copy2(source, destination / name)


def _model_declaration() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "profile": "swift-f0-0.1.2-cpu-internal-evaluation",
        "version": "0.1.2",
        "actualSHA256": MODEL_SHA256,
        "sizeBytes": MODEL_SIZE_BYTES,
        "provider": "CPUExecutionProvider",
        "sourceLicense": "MIT",
        "weightLicense": "unknown",
        "distribution": "internal-evaluation-only",
    }


def _validate_model(path: Path) -> None:
    info = _regular(path, "swift_f0 model.onnx")
    if info.st_size != MODEL_SIZE_BYTES or _sha256(path) != MODEL_SHA256:
        raise PackagingError("swift_f0 model.onnx differs from the approved internal-evaluation artifact")


def _manifest(root: Path) -> dict[str, object]:
    value = prepare_engine._manifest(root)
    value.update(
        kind="d-pitch-engine",
        providerScript="provider/d_pitch_analysis_backend.py",
        vendorDirectory="python/lib/python3.12/site-packages/swift_f0",
        modelManifestsDirectory="model-manifests",
    )
    return value


def _verify_no_installation_records(root: Path) -> None:
    for current, _directories, names in os.walk(root, followlinks=False):
        for name in names:
            if name in INSTALLATION_RECORDS:
                raise PackagingError(f"installation record was not removed: {Path(current) / name}")


def prepare(args: argparse.Namespace) -> None:
    if getattr(args, "internal_evaluation_ack", False) is not True:
        raise PackagingError("--internal-evaluation-ack is required")
    python_root = prepare_engine._absolute_directory(args.python_root, "python-root")
    site = prepare_engine._absolute_directory(args.site_packages, "site-packages")
    provider = prepare_engine._absolute_directory(args.provider_directory, "provider-directory")
    output = prepare_engine._absolute_output(args.output)
    prepare_engine._reject_overlap(output, [python_root, site, provider])
    prepare_engine._validate_tree(provider, "provider-directory")

    staging = Path(tempfile.mkdtemp(prefix=".d-pitch-engine-", dir=output.parent))
    try:
        _copy_runtime(python_root, site, staging / "python")
        _copy_providers(provider, staging / "provider")
        copied_model = staging / "python/lib/python3.12/site-packages/swift_f0/model.onnx"
        _validate_model(copied_model)
        (staging / "model-manifests").mkdir()
        declaration = _model_declaration()
        (staging / "model-manifests/swift-f0.json").write_text(
            json.dumps(declaration, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )
        _verify_no_installation_records(staging)
        manifest = _manifest(staging)
        if manifest["files"] != _manifest(staging)["files"]:
            raise PackagingError("post-copy pitch manifest integrity verification failed")
        (staging / "engine.json").write_text(
            json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )
        prepare_engine._publish_exclusive(staging, output)
    except (OSError, shutil.Error, UnicodeError) as error:
        raise PackagingError(f"prepare pitch engine: {error}") from error
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-root", required=True)
    parser.add_argument("--site-packages", required=True)
    parser.add_argument("--provider-directory", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--internal-evaluation-ack", action="store_true", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        prepare(parse_arguments(sys.argv[1:] if argv is None else argv))
    except (PackagingError, OSError, shutil.Error, UnicodeError) as error:
        prepare_engine._safe_message(sys.stderr, f"prepare_pitch_engine: {error}")
        return 2
    message = "Prepared fixed SwiftF0 pitch engine for internal evaluation; runtime/model execution/signature verification: not run."
    return 0 if prepare_engine._safe_message(sys.stdout, message) else 2


if __name__ == "__main__":
    raise SystemExit(main())
