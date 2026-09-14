#!/usr/bin/env python3
"""Prepare a self-contained, unverified D video-engine candidate."""

from __future__ import annotations

import argparse
import email.parser
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile


AUDIO_PACKAGING = Path(__file__).resolve().parents[2] / "Audio/Packaging"
if str(AUDIO_PACKAGING) not in sys.path:
    sys.path.insert(0, str(AUDIO_PACKAGING))
import prepare_engine  # type: ignore[import-not-found]  # noqa: E402


PackagingError = prepare_engine.PackagingError
VIDEO_SCRIPTS = ("d_video_run.py", "d_video_model.py", "d_video_prepare.py")
TOKENIZER_DIGESTS = {
    "special_tokens_map.json": "7b8a9f5040adb67b5805abdfd42c1f8d0f3d0e711f10726580eb3789cd0ad61d",
    "spiece.model": "e3909a67b780650b35cf529ac782ad2b6b26e6d1f849d3fbb6a872905f452458",
    "tokenizer.json": "6e197b4d3dbd71da14b4eb255f4fa91c9c1f2068b20a2de2472967ca3d22602b",
    "tokenizer_config.json": "ed9a3a8b0faa71a70a32847e0435fe036e6e112d4df4edb7bb48a921e344dc05",
}
REQUIRED_DISTRIBUTIONS = {
    "mlx": "0.31.1",
    "mlx-metal": "0.31.1",
    "numpy": "2.4.3",
    "tokenizers": "0.22.2",
    "ftfy": "6.3.1",
    "wcwidth": "0.8.3",
}
REQUIRED_PACKAGES = ("mlx", "numpy", "tokenizers", "ftfy", "wcwidth")
MODEL_DECLARATION = "wan21.json"
INSTALLATION_RECORDS = {"direct_url.json", "RECORD", "INSTALLER", "REQUESTED"}
# The official 0.22.2 wheel omits its Apache text. Preserve the matching tagged
# source license without altering the installed environment or using the network.
TOKENIZERS_LICENSE = Path(__file__).parent / "Licenses/tokenizers-0.22.2-LICENSE.txt"
TOKENIZERS_LICENSE_SHA256 = "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _regular(path: Path, label: str, *, executable: bool = False) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise PackagingError(f"{label} is missing or unreadable: {path}") from error
    if not stat.S_ISREG(info.st_mode):
        raise PackagingError(f"{label} must be a regular non-symlink file: {path}")
    if executable and not info.st_mode & 0o111:
        raise PackagingError(f"{label} must be executable: {path}")


def _normalized_distribution(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def _metadata(path: Path) -> tuple[str, str]:
    metadata = path / "METADATA"
    _regular(metadata, "distribution METADATA")
    try:
        with metadata.open("r", encoding="utf-8") as handle:
            parsed = email.parser.Parser().parse(handle, headersonly=True)
    except (OSError, UnicodeError) as error:
        raise PackagingError(f"distribution METADATA is unreadable: {metadata}") from error
    name, version = parsed.get("Name"), parsed.get("Version")
    if not name or not version:
        raise PackagingError(f"distribution METADATA lacks Name or Version: {metadata}")
    return name, version


def _distribution(site: Path, name: str, version: str) -> Path:
    matches: list[Path] = []
    for entry in site.iterdir():
        if not entry.name.endswith(".dist-info"):
            continue
        if entry.is_symlink() or not entry.is_dir():
            continue
        actual_name, actual_version = _metadata(entry)
        if _normalized_distribution(actual_name) == _normalized_distribution(name):
            if actual_version != version:
                raise PackagingError(f"{name} must be version {version}, found {actual_version}")
            matches.append(entry)
    if len(matches) != 1:
        raise PackagingError(f"site-packages must contain exactly one {name} {version} dist-info directory")
    result = matches[0]
    prepare_engine._validate_tree(result, f"{name} dist-info")
    licenses = [
        path for path in result.rglob("*")
        if path.is_file() and path.name.lower().startswith(("license", "copying", "notice"))
    ]
    if not licenses:
        if not (name == "tokenizers" and version == "0.22.2"
                and not TOKENIZERS_LICENSE.is_symlink() and TOKENIZERS_LICENSE.is_file()
                and _sha256(TOKENIZERS_LICENSE) == TOKENIZERS_LICENSE_SHA256):
            raise PackagingError(f"{name} dist-info must include license material")
    return result


def _selected_site_entries(site: Path) -> list[Path]:
    selected: list[Path] = []
    for package in REQUIRED_PACKAGES:
        path = site / package
        if path.is_symlink() or not path.is_dir():
            raise PackagingError(f"site-packages missing regular package directory: {package}")
        prepare_engine._validate_tree(path, f"site package {package}")
        selected.append(path)
        native = site / f"{package}.libs"
        if os.path.lexists(native):
            if native.is_symlink() or not native.is_dir():
                raise PackagingError(f"native package resources must be a directory: {native}")
            prepare_engine._validate_tree(native, f"native package resources {native.name}")
            selected.append(native)
    optional_metal = site / "mlx_metal"
    if os.path.lexists(optional_metal):
        if optional_metal.is_symlink() or not optional_metal.is_dir():
            raise PackagingError("mlx_metal must be a regular directory when present")
        prepare_engine._validate_tree(optional_metal, "site package mlx_metal")
        selected.append(optional_metal)
    selected.extend(_distribution(site, name, version) for name, version in REQUIRED_DISTRIBUTIONS.items())
    return selected


def _copy_selected_site(site: Path, destination: Path) -> None:
    destination.mkdir(parents=True)
    for entry in _selected_site_entries(site):
        target = destination / entry.name
        if target.exists():
            raise PackagingError(f"duplicate selected site-packages entry: {entry.name}")
        prepare_engine._copy_tree(entry, target)
        if entry.name.endswith(".dist-info"):
            has_license = any(p.is_file() and p.name.lower().startswith(("license", "copying", "notice"))
                              for p in target.rglob("*"))
            if entry.name == "tokenizers-0.22.2.dist-info" and not has_license:
                if (TOKENIZERS_LICENSE.is_symlink() or not TOKENIZERS_LICENSE.is_file()
                        or _sha256(TOKENIZERS_LICENSE) != TOKENIZERS_LICENSE_SHA256):
                    raise PackagingError("tokenizers source license is missing or changed")
                # Use the same protected-copy checks as the explicitly supplied providers.
                license_target = target / "licenses/D-tokenizers-LICENSE.txt"
                license_target.parent.mkdir(exist_ok=True)
                _copy_verified_source(TOKENIZERS_LICENSE, license_target, "tokenizers source license")
                if _sha256(license_target) != TOKENIZERS_LICENSE_SHA256:
                    raise PackagingError("tokenizers source license changed while copying")
            for name in INSTALLATION_RECORDS:
                record = target / name
                if record.is_file():
                    record.unlink()


def _validate_model_declaration(path: Path) -> None:
    _regular(path, "video model declaration")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackagingError("video model declaration is unreadable") from error
    expected = {
        "schemaVersion": 1,
        "repository": "Wan-AI/Wan2.1-T2V-1.3B",
        "revision": "37ec512624d61f7aa208f7ea8140a131f93afc9a",
        "profile": "wan21-t2v-1.3b-bf16-v1",
        "precision": {
            "text": "BF16",
            "diffusion": "BF16 with original FP32 time/head/modulation/norm tensors",
            "vae": "F32",
        },
    }
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value != expected:
        raise PackagingError("video model declaration differs from the fixed Wan2.1 profile")


def _identity(info: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_size,
        stat.S_IMODE(info.st_mode),
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _hash_descriptor(descriptor: int) -> tuple[str, int]:
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    count = 0
    while True:
        block = os.read(descriptor, 1024 * 1024)
        if not block:
            break
        digest.update(block)
        count += len(block)
    return digest.hexdigest(), count


def _copy_descriptor(source_descriptor: int, destination: Path, mode: int) -> None:
    destination_descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        os.lseek(source_descriptor, 0, os.SEEK_SET)
        while True:
            block = os.read(source_descriptor, 1024 * 1024)
            if not block:
                break
            remaining = memoryview(block)
            while remaining:
                written = os.write(destination_descriptor, remaining)
                if written <= 0:
                    raise OSError("provider copy made no progress")
                remaining = remaining[written:]
        os.fchmod(destination_descriptor, mode)
        os.fsync(destination_descriptor)
    finally:
        os.close(destination_descriptor)


def _copy_verified_source(source: Path, destination: Path, label: str) -> None:
    try:
        initial_path = source.lstat()
        if not stat.S_ISREG(initial_path.st_mode):
            raise PackagingError(f"{label} must be a regular non-symlink file: {source}")
        descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise PackagingError(f"{label} is missing, unreadable, or unsafe: {source}") from error
    try:
        initial_open = os.fstat(descriptor)
        if not stat.S_ISREG(initial_open.st_mode) or _identity(initial_open) != _identity(initial_path):
            raise PackagingError(f"{label} changed before it could be copied")
        initial_digest, initial_count = _hash_descriptor(descriptor)
        if initial_count != initial_open.st_size:
            raise PackagingError(f"{label} size changed while hashing")
        _copy_descriptor(descriptor, destination, stat.S_IMODE(initial_open.st_mode))

        final_open = os.fstat(descriptor)
        final_digest, final_count = _hash_descriptor(descriptor)
        final_path = source.lstat()
        if (
            _identity(final_open) != _identity(initial_open)
            or _identity(final_path) != _identity(initial_open)
            or final_count != initial_count
            or final_digest != initial_digest
        ):
            raise PackagingError(f"{label} changed or was replaced while being copied")
        reopened = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            reopened_info = os.fstat(reopened)
            reopened_digest, reopened_count = _hash_descriptor(reopened)
        finally:
            os.close(reopened)
        if (
            _identity(reopened_info) != _identity(initial_open)
            or reopened_count != initial_count
            or reopened_digest != initial_digest
        ):
            raise PackagingError(f"{label} changed or was replaced after copying")
    except OSError as error:
        raise PackagingError(f"{label} could not be copied safely: {error}") from error
    finally:
        os.close(descriptor)

    copied = destination.lstat()
    if (
        not stat.S_ISREG(copied.st_mode)
        or copied.st_size != initial_count
        or stat.S_IMODE(copied.st_mode) != stat.S_IMODE(initial_open.st_mode)
        or _sha256(destination) != initial_digest
    ):
        raise PackagingError(f"copied file differs from verified source: {label}")


def _copy_inputs(
    staging: Path,
    python_root: Path,
    site_packages: Path,
    video_root: Path,
    audio_provider: Path,
    tokenizer: Path,
) -> None:
    interpreter = python_root / "bin/python3.12"
    stdlib = python_root / "lib/python3.12"
    _regular(interpreter, "python interpreter", executable=True)
    prepare_engine._reject_symlink_ancestors(interpreter.parent, "python interpreter")
    prepare_engine._reject_symlink_ancestors(stdlib, "stdlib")
    if stdlib.is_symlink() or not stdlib.is_dir():
        raise PackagingError("python-root must contain regular lib/python3.12")
    for relative in ("LICENSE.txt", "encodings/__init__.py"):
        _regular(stdlib / relative, f"stdlib {relative}")
    prepare_engine._validate_tree(stdlib, "stdlib", skip=True)

    source_python = video_root / "Python"
    source_vendor = video_root / "Vendor/wan21"
    if source_python.is_symlink() or not source_python.is_dir():
        raise PackagingError("video-root must contain regular Python directory")
    if source_vendor.is_symlink() or not source_vendor.is_dir():
        raise PackagingError("video-root must contain regular Vendor/wan21 directory")
    prepare_engine._validate_tree(source_vendor, "Wan vendor")
    access = audio_provider / "d_audio_access.py"

    for name, expected in TOKENIZER_DIGESTS.items():
        path = tokenizer / name
        _regular(path, f"tokenizer file {name}")
        if _sha256(path) != expected:
            raise PackagingError(f"tokenizer file differs from the pinned revision: {name}")

    declaration = Path(__file__).resolve().parents[1] / "Models" / MODEL_DECLARATION
    _validate_model_declaration(declaration)

    target_python = staging / "python"
    (target_python / "bin").mkdir(parents=True)
    shutil.copy2(interpreter, target_python / "bin/python3")
    prepare_engine._copy_tree(stdlib, target_python / "lib/python3.12", exclude_site_packages=True)
    _copy_selected_site(site_packages, target_python / "lib/python3.12/site-packages")

    provider = staging / "provider"
    provider.mkdir()
    for name in VIDEO_SCRIPTS:
        _copy_verified_source(source_python / name, provider / name, f"video provider {name}")
    _copy_verified_source(access, provider / "d_audio_access.py", "audio access provider")
    prepare_engine._copy_tree(source_vendor, staging / "Vendor/wan21")
    target_tokenizer = staging / "tokenizer"
    target_tokenizer.mkdir()
    for name in TOKENIZER_DIGESTS:
        shutil.copy2(tokenizer / name, target_tokenizer / name)
    target_models = staging / "model-manifests"
    target_models.mkdir()
    shutil.copy2(declaration, target_models / MODEL_DECLARATION)


def _reject_source_paths(root: Path, sources: list[Path]) -> None:
    needles = [os.fsencode(str(path)) for path in sources]
    overlap = max((len(needle) for needle in needles), default=1) - 1
    for current, _directories, files in os.walk(root, followlinks=False):
        for name in files:
            path = Path(current) / name
            previous = b""
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    data = previous + block
                    if any(needle and needle in data for needle in needles):
                        raise PackagingError(f"packaged file contains an installation input path: {path.relative_to(root)}")
                    previous = data[-overlap:] if overlap else b""


def _reject_casefold_collisions(root: Path) -> None:
    inventory: dict[str, str] = {}
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in directories + files:
            relative = (current_path / name).relative_to(root).as_posix()
            folded = relative.casefold()
            previous = inventory.get(folded)
            if previous is not None and previous != relative:
                raise PackagingError(f"packaged inventory has a casefold collision: {previous} and {relative}")
            inventory[folded] = relative


def _manifest(root: Path) -> dict[str, object]:
    value = prepare_engine._manifest(root)
    value.update({
        "kind": "d-video-engine",
        "providerScript": "provider/d_video_run.py",
        "vendorDirectory": "Vendor",
        "modelManifestsDirectory": "model-manifests",
    })
    return value


def prepare(args: argparse.Namespace) -> None:
    python_root = prepare_engine._absolute_directory(args.python_root, "python-root")
    site_packages = prepare_engine._absolute_directory(args.site_packages, "site-packages")
    video_root = prepare_engine._absolute_directory(args.video_root, "video-root")
    audio_provider = prepare_engine._absolute_directory(args.audio_provider_directory, "audio-provider-directory")
    tokenizer = prepare_engine._absolute_directory(args.tokenizer, "tokenizer")
    output = prepare_engine._absolute_output(args.output)
    sources = [python_root, site_packages, video_root, audio_provider, tokenizer]
    prepare_engine._reject_overlap(output, sources)

    staging: Path | None = None
    try:
        staging = Path(tempfile.mkdtemp(prefix=".d-video-engine-", dir=output.parent))
        _copy_inputs(staging, python_root, site_packages, video_root, audio_provider, tokenizer)
        prepare_engine._validate_tree(staging, "prepared video engine")
        _reject_casefold_collisions(staging)
        _reject_source_paths(staging, sources)
        manifest = _manifest(staging)
        if manifest["files"] != _manifest(staging)["files"]:
            raise PackagingError("post-copy manifest integrity verification failed")
        with (staging / "engine.json").open("w", encoding="utf-8", newline="\n") as handle:
            json.dump(manifest, handle, ensure_ascii=False, sort_keys=True, indent=2)
            handle.write("\n")
        prepare_engine._publish_exclusive(staging, output)
    except (OSError, shutil.Error, UnicodeError) as error:
        raise PackagingError(str(error)) from error
    finally:
        if staging is not None and staging.exists():
            shutil.rmtree(staging)


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-root", required=True)
    parser.add_argument("--site-packages", required=True)
    parser.add_argument("--video-root", required=True)
    parser.add_argument("--audio-provider-directory", required=True)
    parser.add_argument("--tokenizer", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        prepare(parse_arguments(sys.argv[1:] if argv is None else argv))
    except (PackagingError, OSError, shutil.Error, UnicodeError) as error:
        prepare_engine._safe_message(sys.stderr, f"prepare_video_engine: {error}")
        return 2
    if not prepare_engine._safe_message(
        sys.stdout,
        "Prepared D video engine candidate; runtime/import/signature verification: unverified.",
    ):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
