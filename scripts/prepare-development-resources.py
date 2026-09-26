#!/usr/bin/env python3
"""Prepare a verified, reusable set of local development engine resources."""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
from typing import Any


SCHEMA_VERSION = 1
RESOURCE_MANIFEST = "development-resources.json"
ENGINE_DIRECTORY = "Engines"
ENGINE_NAMES = (
    "AudioEngine.dengine",
    "MRT2MusicEngine.dengine",
    "VideoEngine.dengine",
    "PitchEngine.dengine",
)
ENGINE_CONTRACTS: dict[str, dict[str, Any]] = {
    "AudioEngine.dengine": {
        "kind": "d-audio-engine",
        "providerScript": "provider/d_audio_backend.py",
        "vendorDirectory": "vendor",
        "required": (
            "python/bin/python3", "provider/d_audio_backend.py",
            "provider/d_audio_access.py", "provider/d_audio_contract.py",
            "model-manifests/sm-music.json", "provider/d_audio_sa3.py",
        ),
    },
    "MRT2MusicEngine.dengine": {
        "kind": "d-mrt2-music-engine",
        "providerScript": "provider/d_audio_mrt2_backend.py",
        "vendorDirectory": "vendor",
        "required": (
            "python/bin/python3", "provider/d_audio_mrt2_backend.py",
            "provider/d_audio_access.py", "provider/d_audio_contract.py",
            "model-manifests/mrt2-small.json", "provider/d_audio_mrt2_contract.py",
            "provider/d_mrt2_export.py",
        ),
    },
    "VideoEngine.dengine": {
        "kind": "d-video-engine",
        "providerScript": "provider/d_video_run.py",
        "vendorDirectory": "Vendor",
        "required": (
            "python/bin/python3", "provider/d_video_run.py", "provider/d_video_model.py",
            "provider/d_video_prepare.py", "provider/d_audio_access.py",
            "model-manifests/wan21.json", "tokenizer/special_tokens_map.json",
            "tokenizer/spiece.model", "tokenizer/tokenizer.json",
            "tokenizer/tokenizer_config.json", "Vendor/wan21/__init__.py",
            "Vendor/wan21/PROVENANCE.json", "Vendor/wan21/LICENSE-MIT.txt",
            "Vendor/wan21/LICENSE-WAN-APACHE-2.0.txt",
        ),
    },
    "PitchEngine.dengine": {
        "kind": "d-pitch-engine",
        "providerScript": "provider/d_pitch_analysis_backend.py",
        "vendorDirectory": "python/lib/python3.12/site-packages/swift_f0",
        "required": (
            "python/bin/python3", "provider/d_pitch_analysis_backend.py",
            "provider/d_audio_access.py", "model-manifests/swift-f0.json",
            "python/lib/python3.12/site-packages/swift_f0/core.py",
            "python/lib/python3.12/site-packages/swift_f0/model.onnx",
        ),
    },
}

MAXIMUM_ENGINE_MANIFEST_BYTES = 4 * 1024 * 1024
MAXIMUM_RESOURCE_MANIFEST_BYTES = 32 * 1024 * 1024
MAXIMUM_FILES_PER_ENGINE = 10_000
MAXIMUM_FILE_BYTES = 512 * 1024 * 1024
MAXIMUM_BYTES_PER_ENGINE = 1024 * 1024 * 1024
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")


class ResourceError(Exception):
    """A controlled validation or filesystem failure."""


def _lexists(path: Path) -> bool:
    return os.path.lexists(path)


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ResourceError(f"JSON contains duplicate key: {key}")
        result[key] = value
    return result


def _read_json(path: Path, label: str, limit: int) -> Any:
    info = _regular_info(path, label)
    if info.st_size > limit:
        raise ResourceError(f"{label} exceeds its size limit: {path}")
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=_strict_object)
    except ResourceError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ResourceError(f"{label} is unreadable or malformed: {path}: {error}") from error


def _reject_symlink_ancestors(path: Path, label: str, *, include_leaf: bool = True) -> None:
    current = Path(path.anchor)
    parts = path.parts[1:] if include_leaf else path.parts[1:-1]
    for part in parts:
        current /= part
        try:
            info = current.lstat()
        except OSError as error:
            raise ResourceError(f"{label} has an unreadable ancestor: {current}: {error}") from error
        if stat.S_ISLNK(info.st_mode):
            raise ResourceError(f"{label} has a symlink ancestor: {current}")
        if not stat.S_ISDIR(info.st_mode):
            raise ResourceError(f"{label} has a non-directory ancestor: {current}")


def _absolute_regular(value: str, label: str) -> Path:
    supplied = Path(value)
    if not supplied.is_absolute():
        raise ResourceError(f"{label} must be an absolute regular file")
    path = Path(os.path.abspath(value))
    _reject_symlink_ancestors(path, label, include_leaf=False)
    _regular_info(path, label)
    return path


def _absolute_directory(value: str, label: str) -> Path:
    if "\x00" in value:
        raise ResourceError(f"{label} contains NUL and is not a valid filesystem path")
    supplied = Path(value)
    if not supplied.is_absolute():
        raise ResourceError(f"{label} must be an absolute non-symlink directory")
    path = Path(os.path.abspath(value))
    _reject_symlink_ancestors(path, label)
    try:
        info = path.lstat()
    except OSError as error:
        raise ResourceError(f"{label} is unreadable: {path}: {error}") from error
    if not stat.S_ISDIR(info.st_mode):
        raise ResourceError(f"{label} must be a non-symlink directory: {path}")
    return path


def _absolute_output(value: str) -> Path:
    supplied = Path(value)
    if not supplied.is_absolute():
        raise ResourceError("--output must be an absolute path")
    path = Path(os.path.abspath(value))
    if path.name in {"", ".", ".."}:
        raise ResourceError("--output must name a resource-set directory")
    parent = path.parent
    _reject_symlink_ancestors(parent, "output parent")
    if not parent.is_dir():
        raise ResourceError(f"output parent is not a directory: {parent}")
    if _lexists(path):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise ResourceError(f"existing output is not a regular directory: {path}")
    return path


def _regular_info(path: Path, label: str) -> os.stat_result:
    try:
        info = path.lstat()
    except OSError as error:
        raise ResourceError(f"{label} is missing or unreadable: {path}: {error}") from error
    if not stat.S_ISREG(info.st_mode):
        raise ResourceError(f"{label} must be a regular non-symlink file: {path}")
    return info


def _inside(root: Path, candidate: Path) -> bool:
    try:
        candidate.relative_to(root)
        return True
    except ValueError:
        return False


def _overlaps(first: Path, second: Path) -> bool:
    return _inside(first, second) or _inside(second, first)


def _normalized_relative(value: object) -> bool:
    return (
        isinstance(value, str)
        and bool(value)
        and not value.startswith("/")
        and "\x00" not in value
        and all(part not in {"", ".", ".."} for part in value.split("/"))
    )


def _hash_regular(path: Path, label: str, limit: int = MAXIMUM_FILE_BYTES) -> tuple[str, os.stat_result]:
    initial = _regular_info(path, label)
    if initial.st_size < 0 or initial.st_size > limit:
        raise ResourceError(f"{label} is outside its size limit: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ResourceError(f"cannot safely open {label}: {path}: {error}") from error
    digest = hashlib.sha256()
    count = 0
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (initial.st_dev, initial.st_ino):
            raise ResourceError(f"{label} changed before it could be read: {path}")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                count += len(block)
                if count > limit:
                    raise ResourceError(f"{label} exceeds its size limit while reading: {path}")
                digest.update(block)
        final = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if count != initial.st_size or identity(initial) != identity(final):
        raise ResourceError(f"{label} changed while being read: {path}")
    return digest.hexdigest(), final


def _validate_symlink(root: Path, path: Path, relative: str) -> str:
    try:
        target = os.readlink(path)
    except OSError as error:
        raise ResourceError(f"cannot read engine symbolic link {relative}: {error}") from error
    if not target or os.path.isabs(target) or "\x00" in target:
        raise ResourceError(f"engine symbolic link must use a relative target: {relative}")
    try:
        resolved = (path.parent / target).resolve(strict=True)
        resolved_root = root.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ResourceError(f"engine symbolic link is dangling or cyclic: {relative}: {error}") from error
    if not _inside(resolved_root, resolved):
        raise ResourceError(f"engine symbolic link escapes its engine: {relative} -> {target}")
    return target


def _walk_engine(root: Path) -> dict[str, Any]:
    directories: list[str] = []
    files: list[dict[str, Any]] = []
    symlinks: list[dict[str, str]] = []
    seen_casefold: dict[str, str] = {}
    total_bytes = 0
    enumeration_error: list[OSError] = []

    def onerror(error: OSError) -> None:
        enumeration_error.append(error)

    for current, directory_names, file_names in os.walk(root, followlinks=False, onerror=onerror):
        current_path = Path(current)
        retained: list[str] = []
        for name in directory_names:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                symlinks.append({"path": relative, "target": _validate_symlink(root, path, relative)})
            elif stat.S_ISDIR(info.st_mode):
                directories.append(relative)
                retained.append(name)
            else:
                raise ResourceError(f"engine contains a special directory entry: {relative}")
        directory_names[:] = retained
        for name in file_names:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                symlinks.append({"path": relative, "target": _validate_symlink(root, path, relative)})
                continue
            if not stat.S_ISREG(info.st_mode):
                raise ResourceError(f"engine contains a special file: {relative}")
            digest, checked = _hash_regular(path, f"engine file {relative}")
            total_bytes += checked.st_size
            if total_bytes > MAXIMUM_BYTES_PER_ENGINE + MAXIMUM_ENGINE_MANIFEST_BYTES:
                raise ResourceError("engine regular files exceed the aggregate size limit")
            files.append({
                "path": relative,
                "sizeBytes": checked.st_size,
                "sha256": digest,
                "executable": bool(checked.st_mode & 0o111),
            })
    if enumeration_error:
        raise ResourceError(f"engine could not be completely enumerated: {enumeration_error[0]}")
    if len(files) + len(symlinks) > MAXIMUM_FILES_PER_ENGINE + 1:
        raise ResourceError("engine exceeds the entry-count limit")
    for relative in directories + [item["path"] for item in files] + [item["path"] for item in symlinks]:
        folded = relative.casefold()
        previous = seen_casefold.get(folded)
        if previous is not None and previous != relative:
            raise ResourceError(f"engine has a case-insensitive path collision: {previous} and {relative}")
        seen_casefold[folded] = relative
    directories.sort()
    files.sort(key=lambda item: item["path"])
    symlinks.sort(key=lambda item: item["path"])
    return {"directories": directories, "files": files, "symlinks": symlinks}


def _strict_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise ResourceError(
            f"{label} fields differ from schema; missing={sorted(expected - set(value))}, "
            f"unknown={sorted(set(value) - expected)}"
        )


def inspect_engine(root: Path, name: str) -> dict[str, Any]:
    if name not in ENGINE_CONTRACTS:
        raise ResourceError(f"unknown engine name: {name}")
    root = _absolute_directory(str(root), f"engine {name}")
    manifest_path = root / "engine.json"
    manifest = _read_json(manifest_path, f"{name} engine manifest", MAXIMUM_ENGINE_MANIFEST_BYTES)
    if not isinstance(manifest, dict):
        raise ResourceError(f"{name} engine manifest root must be an object")
    exact = {
        "schemaVersion": 1,
        "kind": ENGINE_CONTRACTS[name]["kind"],
        "pythonABI": "3.12",
        "pythonExecutable": "python/bin/python3",
        "providerScript": ENGINE_CONTRACTS[name]["providerScript"],
        "vendorDirectory": ENGINE_CONTRACTS[name]["vendorDirectory"],
        "modelManifestsDirectory": "model-manifests",
    }
    _strict_keys(manifest, set(exact) | {"files"}, f"{name} engine manifest")
    for key, expected in exact.items():
        actual = manifest.get(key)
        if key == "schemaVersion" and type(actual) is not int:
            actual = None
        if actual != expected:
            raise ResourceError(f"{name} engine manifest {key} differs from the fixed contract")
    declarations = manifest.get("files")
    if not isinstance(declarations, list) or len(declarations) > MAXIMUM_FILES_PER_ENGINE:
        raise ResourceError(f"{name} engine files list is missing or exceeds the limit")
    declared: dict[str, dict[str, Any]] = {}
    aggregate = 0
    for entry in declarations:
        if not isinstance(entry, dict):
            raise ResourceError(f"{name} engine file declaration must be an object")
        _strict_keys(entry, {"path", "sizeBytes", "sha256", "executable"}, f"{name} file declaration")
        path = entry.get("path")
        size = entry.get("sizeBytes")
        digest = entry.get("sha256")
        executable = entry.get("executable")
        if (
            not _normalized_relative(path)
            or path == "engine.json"
            or type(size) is not int
            or size < 0
            or size > MAXIMUM_FILE_BYTES
            or not isinstance(digest, str)
            or SHA256_PATTERN.fullmatch(digest) is None
            or type(executable) is not bool
            or path in declared
        ):
            raise ResourceError(f"{name} engine file declaration is invalid or duplicated")
        if aggregate > MAXIMUM_BYTES_PER_ENGINE - size:
            raise ResourceError(f"{name} engine declarations exceed the aggregate size limit")
        aggregate += size
        declared[path] = entry
    for required in ENGINE_CONTRACTS[name]["required"]:
        if required not in declared:
            raise ResourceError(f"{name} engine manifest lacks required file: {required}")

    inventory = _walk_engine(root)
    vendor_directory = ENGINE_CONTRACTS[name]["vendorDirectory"]
    if vendor_directory not in inventory["directories"]:
        raise ResourceError(f"{name} engine vendorDirectory is not a real directory: {vendor_directory}")
    actual_files = [item for item in inventory["files"] if item["path"] != "engine.json"]
    actual = {item["path"]: item for item in actual_files}
    if actual != declared:
        missing = sorted(set(declared) - set(actual))
        unknown = sorted(set(actual) - set(declared))
        differing = sorted(path for path in set(actual) & set(declared) if actual[path] != declared[path])
        raise ResourceError(
            f"{name} engine manifest does not match regular files; "
            f"missing={missing[:5]}, undeclared={unknown[:5]}, differing={differing[:5]}"
        )
    if declarations != actual_files:
        raise ResourceError(f"{name} engine file declarations are not in canonical path order")
    manifest_record = next((item for item in inventory["files"] if item["path"] == "engine.json"), None)
    if manifest_record is None:
        raise ResourceError(f"{name} engine manifest disappeared during validation")
    return inventory


def _load_config(path: Path) -> tuple[dict[str, Path], str]:
    value = _read_json(path, "development resource config", MAXIMUM_ENGINE_MANIFEST_BYTES)
    if not isinstance(value, dict):
        raise ResourceError("config root must be an object")
    _strict_keys(value, {"schemaVersion", "engines"}, "config")
    if type(value.get("schemaVersion")) is not int or value["schemaVersion"] != SCHEMA_VERSION:
        raise ResourceError("config schemaVersion must be integer 1")
    engines = value.get("engines")
    if not isinstance(engines, dict):
        raise ResourceError("config engines must be an object")
    _strict_keys(engines, set(ENGINE_NAMES), "config engines")
    result: dict[str, Path] = {}
    for name in ENGINE_NAMES:
        supplied = engines[name]
        if not isinstance(supplied, str) or not supplied:
            raise ResourceError(f"config engine path must be a non-empty string: {name}")
        result[name] = _absolute_directory(supplied, f"config engine {name}")
    canonical = json.dumps(
        {"schemaVersion": SCHEMA_VERSION, "engines": {name: str(result[name]) for name in ENGINE_NAMES}},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    config_digest = hashlib.sha256(canonical).hexdigest()
    return result, config_digest


def _resource_manifest(config_digest: str, inventories: dict[str, dict[str, Any]]) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "d-development-resources",
        "configurationSHA256": config_digest,
        "engines": {name: inventories[name] for name in ENGINE_NAMES},
    }


def _write_json_new(path: Path, value: dict[str, Any]) -> None:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode("utf-8") + b"\n"
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except OSError as error:
        raise ResourceError(f"cannot exclusively create manifest: {path}: {error}") from error
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        try:
            path.unlink()
        except OSError:
            pass
        raise


def _publish_exclusive(staging: Path, output: Path) -> None:
    if _lexists(output):
        raise ResourceError(f"output appeared before publication: {output}")
    if sys.platform == "darwin":
        try:
            renameatx_np = ctypes.CDLL(None, use_errno=True).renameatx_np
        except AttributeError as error:
            raise ResourceError("exclusive directory publication is unavailable") from error
        renameatx_np.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
        renameatx_np.restype = ctypes.c_int
        if renameatx_np(-2, os.fsencode(staging), -2, os.fsencode(output), 0x00000004) != 0:
            number = ctypes.get_errno()
            raise ResourceError(f"cannot exclusively publish output: {output}: {os.strerror(number)}")
        return
    # Non-Darwin support is for fixture portability. The second existence check
    # avoids ordinary overwrites, but only Darwin provides the required atomic
    # no-replace primitive used in production.
    if _lexists(output):
        raise ResourceError(f"output appeared before publication: {output}")
    try:
        os.rename(staging, output)
    except OSError as error:
        raise ResourceError(f"cannot publish output: {output}: {error}") from error


def validate_prepared(root: Path, expected_config_digest: str | None = None) -> dict[str, Any]:
    root = _absolute_directory(str(root), "prepared resource set")
    try:
        root_entries = {entry.name for entry in root.iterdir()}
    except OSError as error:
        raise ResourceError(f"cannot enumerate prepared resource set: {root}: {error}") from error
    expected_entries = {ENGINE_DIRECTORY, RESOURCE_MANIFEST}
    if root_entries != expected_entries:
        raise ResourceError(
            f"prepared resource set contains unknown or missing entries; "
            f"missing={sorted(expected_entries - root_entries)}, unknown={sorted(root_entries - expected_entries)}"
        )
    manifest = _read_json(root / RESOURCE_MANIFEST, "development resource manifest", MAXIMUM_RESOURCE_MANIFEST_BYTES)
    if not isinstance(manifest, dict):
        raise ResourceError("development resource manifest root must be an object")
    _strict_keys(manifest, {"schemaVersion", "kind", "configurationSHA256", "engines"}, "development resource manifest")
    if type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1:
        raise ResourceError("development resource manifest schemaVersion must be integer 1")
    if manifest.get("kind") != "d-development-resources":
        raise ResourceError("development resource manifest kind is invalid")
    config_digest = manifest.get("configurationSHA256")
    if not isinstance(config_digest, str) or SHA256_PATTERN.fullmatch(config_digest) is None:
        raise ResourceError("development resource manifest configurationSHA256 is invalid")
    if expected_config_digest is not None and config_digest != expected_config_digest:
        raise ResourceError("existing output belongs to a different configuration")
    engines = manifest.get("engines")
    if not isinstance(engines, dict):
        raise ResourceError("development resource manifest engines must be an object")
    _strict_keys(engines, set(ENGINE_NAMES), "development resource manifest engines")
    engine_root = _absolute_directory(str(root / ENGINE_DIRECTORY), "prepared Engines")
    try:
        actual_names = {entry.name for entry in engine_root.iterdir()}
    except OSError as error:
        raise ResourceError(f"cannot enumerate prepared Engines: {error}") from error
    if actual_names != set(ENGINE_NAMES):
        raise ResourceError(
            f"prepared Engines contains unknown or missing entries; "
            f"missing={sorted(set(ENGINE_NAMES) - actual_names)}, unknown={sorted(actual_names - set(ENGINE_NAMES))}"
        )
    for name in ENGINE_NAMES:
        recorded = engines[name]
        if not isinstance(recorded, dict):
            raise ResourceError(f"prepared inventory is not an object: {name}")
        _strict_keys(recorded, {"directories", "files", "symlinks"}, f"prepared inventory {name}")
        actual = inspect_engine(engine_root / name, name)
        if actual != recorded:
            raise ResourceError(f"prepared engine inventory differs from its resource manifest: {name}")
    return manifest


def prepare(config_path: Path, output: Path) -> str:
    engines, config_digest = _load_config(config_path)
    for name, engine in engines.items():
        if _overlaps(output, engine):
            raise ResourceError(f"output overlaps input engine {name}: {output} and {engine}")
    source_inventories = {name: inspect_engine(engines[name], name) for name in ENGINE_NAMES}
    if _lexists(output):
        existing = validate_prepared(output, config_digest)
        if existing["engines"] != source_inventories:
            raise ResourceError("existing output belongs to changed engine inputs")
        return "reused"

    staging = Path(tempfile.mkdtemp(prefix=".d-development-resources-", dir=output.parent))
    published = False
    try:
        engine_destination = staging / ENGINE_DIRECTORY
        engine_destination.mkdir(mode=0o700)
        for name in ENGINE_NAMES:
            shutil.copytree(engines[name], engine_destination / name, symlinks=True, copy_function=shutil.copy2)
        copied_inventories = {
            name: inspect_engine(engine_destination / name, name) for name in ENGINE_NAMES
        }
        if copied_inventories != source_inventories:
            raise ResourceError("copied engine inventory differs from its input")
        _write_json_new(staging / RESOURCE_MANIFEST, _resource_manifest(config_digest, copied_inventories))
        validate_prepared(staging, config_digest)
        _publish_exclusive(staging, output)
        published = True
        return "prepared"
    except (OSError, shutil.Error, UnicodeError) as error:
        raise ResourceError(f"resource preparation failed: {error}") from error
    finally:
        if not published and staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def _neutralize_failed_stream(stream: Any) -> None:
    """Let normal interpreter cleanup proceed after a descriptor write failure."""
    try:
        descriptor = stream.fileno()
    except (AttributeError, OSError, ValueError):
        return
    try:
        with open(os.devnull, "w", encoding="utf-8") as sink:
            os.dup2(sink.fileno(), descriptor)
    except OSError:
        return


def _safe_report(stream: Any, value: dict[str, Any]) -> bool:
    try:
        payload = json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n"
        if stream.write(payload) != len(payload):
            raise OSError("short stream write")
        stream.flush()
        return True
    except (AttributeError, OSError, UnicodeError, ValueError):
        _neutralize_failed_stream(stream)
        return False


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="absolute schemaVersion 1 local JSON configuration")
    parser.add_argument("--output", required=True, help="absolute prepared resource-set path")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_arguments(sys.argv[1:] if argv is None else argv)
        config_path = _absolute_regular(args.config, "config")
        output = _absolute_output(args.output)
        if _overlaps(output, config_path):
            raise ResourceError(f"output overlaps config: {output} and {config_path}")
        status = prepare(config_path, output)
        reported = _safe_report(sys.stdout, {
            "schemaVersion": 1,
            "status": status,
            "output": str(output),
            "engines": list(ENGINE_NAMES),
            "runtimeVerification": "not-run",
        })
        if not reported:
            _safe_report(sys.stderr, {
                "schemaVersion": 1,
                "status": "failed",
                "error": "could not write the success report to stdout",
                "runtimeVerification": "not-run",
            })
        return 0 if reported else 2
    except (ResourceError, OSError, shutil.Error, UnicodeError) as error:
        _safe_report(sys.stderr, {
            "schemaVersion": 1,
            "status": "failed",
            "error": str(error),
            "runtimeVerification": "not-run",
        })
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
