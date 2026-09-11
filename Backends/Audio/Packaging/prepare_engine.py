#!/usr/bin/env python3
"""Prepare a self-contained, unverified D audio-engine candidate."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import uuid


class PackagingError(Exception):
    """A controlled packaging failure (reported to the caller as exit 2)."""


IGNORED_SITE_ENTRIES = {"pip", "_distutils_hack", "distutils-precedence.pth"}
REQUIRED_PACKAGES = ("mlx", "mlx_metal", "numpy", "sentencepiece")
SKIPPED_NAMES = {"__pycache__", ".DS_Store", ".git"}


def _lexists(path: Path) -> bool:
    return os.path.lexists(path)


def _absolute_directory(value: str, label: str) -> Path:
    supplied = Path(value)
    if not supplied.is_absolute():
        raise PackagingError(f"{label} must be an existing absolute, non-symlink directory: {supplied}")
    path = Path(os.path.abspath(value))
    if path.is_symlink() or not path.is_dir():
        raise PackagingError(f"{label} must be an existing absolute, non-symlink directory: {path}")
    return path


def _absolute_output(value: str) -> Path:
    if not Path(value).is_absolute():
        raise PackagingError("output must be an absolute path")
    path = Path(os.path.abspath(value))
    if _lexists(path):
        raise PackagingError(f"output already exists: {path}")
    parent = path.parent
    if parent.is_symlink() or not parent.is_dir():
        raise PackagingError(f"output parent must be an existing non-symlink directory: {parent}")
    return path


def _is_ancestor_or_same(first: Path, second: Path) -> bool:
    try:
        second.relative_to(first)
        return True
    except ValueError:
        return False


def _reject_overlap(output: Path, roots: list[Path]) -> None:
    for root in roots:
        if _is_ancestor_or_same(root, output) or _is_ancestor_or_same(output, root):
            raise PackagingError(f"output overlaps input root: {output} and {root}")


def _validate_tree(root: Path, label: str) -> None:
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        if current_path.is_symlink():
            raise PackagingError(f"{label} contains symlink: {current_path}")
        for name in directories + files:
            path = current_path / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise PackagingError(f"{label} contains symlink: {path}")
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise PackagingError(f"{label} contains special file: {path}")


def _should_skip(relative: Path) -> bool:
    return any(part in SKIPPED_NAMES for part in relative.parts) or relative.suffix in {".pyc", ".pyo"}


def _copy_tree(source: Path, destination: Path, *, exclude_site_packages: bool = False) -> None:
    for current, directories, files in os.walk(source, followlinks=False):
        current_path = Path(current)
        relative_current = current_path.relative_to(source)
        directories[:] = [name for name in directories if not _should_skip(relative_current / name)]
        (destination / relative_current).mkdir(parents=True, exist_ok=True)
        for filename in files:
            relative = relative_current / filename
            if _should_skip(relative):
                continue
            if exclude_site_packages and relative.parts and relative.parts[0] == "site-packages":
                continue
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(current_path / filename, target)


def _dist_info_matches(entry: str, package: str) -> bool:
    normalized = package.replace("_", "-")
    return entry.endswith(".dist-info") and (entry.startswith(package + "-") or entry.startswith(normalized + "-"))


def _site_entry_allowed(entry: str) -> bool:
    if entry in REQUIRED_PACKAGES:
        return True
    if entry.endswith(".libs") and entry[:-5] in REQUIRED_PACKAGES:
        return True
    if any(_dist_info_matches(entry, package) for package in REQUIRED_PACKAGES):
        return True
    if entry in IGNORED_SITE_ENTRIES or entry.startswith("pip-") and entry.endswith(".dist-info"):
        return True
    return entry.startswith("setuptools")


def _copy_site_packages(source: Path, destination: Path) -> None:
    entries = sorted(source.iterdir(), key=lambda item: item.name)
    missing = [package for package in REQUIRED_PACKAGES if not (source / package).exists()]
    missing_metadata = [
        package for package in REQUIRED_PACKAGES
        if not any(_dist_info_matches(entry.name, package) for entry in entries)
    ]
    if missing or missing_metadata:
        raise PackagingError(
            "site-packages missing required components: " + ", ".join(missing + missing_metadata)
        )
    for entry in entries:
        if not _site_entry_allowed(entry.name):
            raise PackagingError(f"unknown site-packages component refused: {entry.name}")
    for entry in entries:
        if entry.name in IGNORED_SITE_ENTRIES or entry.name.startswith("pip-") and entry.name.endswith(".dist-info") or entry.name.startswith("setuptools"):
            continue
        target = destination / entry.name
        if entry.is_dir():
            _copy_tree(entry, target)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(entry, target)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _manifest(root: Path) -> dict[str, object]:
    files: list[dict[str, object]] = []
    for current, _directories, names in os.walk(root, followlinks=False):
        for name in names:
            path = Path(current) / name
            relative = path.relative_to(root).as_posix()
            if relative == "engine.json":
                continue
            info = path.stat()
            files.append({
                "path": relative,
                "sizeBytes": info.st_size,
                "sha256": _sha256(path),
                "executable": bool(info.st_mode & 0o111),
            })
    files.sort(key=lambda item: str(item["path"]))
    return {
        "schemaVersion": 1,
        "kind": "d-audio-engine",
        "pythonABI": "3.12",
        "pythonExecutable": "python/bin/python3",
        "providerScript": "provider/d_audio_backend.py",
        "vendorDirectory": "vendor",
        "modelManifestsDirectory": "model-manifests",
        "files": files,
    }


def _verify_manifest(root: Path, manifest: dict[str, object]) -> None:
    expected = manifest["files"]
    if not isinstance(expected, list):
        raise PackagingError("internal manifest files value is invalid")
    actual = _manifest(root)["files"]
    if expected != actual:
        raise PackagingError("post-copy manifest integrity verification failed")


def _publish_exclusive(staging: Path, output: Path) -> None:
    if sys.platform != "darwin":
        raise PackagingError("exclusive directory publication is supported only on macOS")
    try:
        renameatx_np = ctypes.CDLL(None, use_errno=True).renameatx_np
    except AttributeError as error:
        raise PackagingError("exclusive directory publication is unavailable") from error
    renameatx_np.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    renameatx_np.restype = ctypes.c_int
    # Darwin's <stdio.h>: RENAME_EXCL prevents replacement if destination exists.
    result = renameatx_np(-2, os.fsencode(staging), -2, os.fsencode(output), 0x00000004)
    if result != 0:
        error = ctypes.get_errno()
        if error == 17:
            raise PackagingError(f"output appeared during publication: {output}")
        raise PackagingError(f"exclusive publication failed: {os.strerror(error)}")


def prepare(args: argparse.Namespace) -> None:
    python_root = _absolute_directory(args.python_root, "python-root")
    site_packages = _absolute_directory(args.site_packages, "site-packages")
    provider = _absolute_directory(args.provider_directory, "provider-directory")
    vendor = _absolute_directory(args.vendor_directory, "vendor-directory")
    manifests = _absolute_directory(args.model_manifests, "model-manifests")
    output = _absolute_output(args.output)
    roots = [python_root, site_packages, provider, vendor, manifests]
    _reject_overlap(output, roots)
    for root, label in zip(roots, ("python-root", "site-packages", "provider-directory", "vendor-directory", "model-manifests")):
        _validate_tree(root, label)

    interpreter = python_root / "bin" / "python3.12"
    stdlib = python_root / "lib" / "python3.12"
    if interpreter.is_symlink() or not interpreter.is_file():
        raise PackagingError("python-root must contain regular file bin/python3.12")
    if not stdlib.is_dir() or stdlib.is_symlink() or not (stdlib / "LICENSE.txt").is_file():
        raise PackagingError("python-root must contain lib/python3.12/LICENSE.txt")
    if not (provider / "d_audio_backend.py").is_file():
        raise PackagingError("provider-directory must contain d_audio_backend.py")

    staging: Path | None = None
    try:
        staging = Path(tempfile.mkdtemp(prefix=".d-audio-engine-", dir=output.parent))
        target_python = staging / "python"
        (target_python / "bin").mkdir(parents=True)
        shutil.copy2(interpreter, target_python / "bin" / "python3")
        _copy_tree(stdlib, target_python / "lib" / "python3.12", exclude_site_packages=True)
        _copy_site_packages(site_packages, target_python / "lib" / "python3.12" / "site-packages")
        _copy_tree(provider, staging / "provider")
        _copy_tree(vendor, staging / "vendor")
        _copy_tree(manifests, staging / "model-manifests")
        manifest = _manifest(staging)
        _verify_manifest(staging, manifest)
        with (staging / "engine.json").open("w", encoding="utf-8", newline="\n") as handle:
            json.dump(manifest, handle, ensure_ascii=False, sort_keys=True, indent=2)
            handle.write("\n")
        _publish_exclusive(staging, output)
    except (OSError, shutil.Error) as error:
        raise PackagingError(str(error)) from error
    finally:
        if staging is not None and staging.exists():
            shutil.rmtree(staging)


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-root", required=True)
    parser.add_argument("--site-packages", required=True)
    parser.add_argument("--provider-directory", required=True)
    parser.add_argument("--vendor-directory", required=True)
    parser.add_argument("--model-manifests", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        prepare(parse_arguments(sys.argv[1:] if argv is None else argv))
    except (PackagingError, OSError, shutil.Error) as error:
        print(f"prepare_engine: {error}", file=sys.stderr)
        return 2
    print("Prepared D audio engine candidate; runtime/import/signature verification: unverified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
