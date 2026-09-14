#!/usr/bin/env python3
"""Build one isolated, fully packaged D Development.app from pinned local inputs.

Packaging success is not runtime, GUI, notarization, or model verification.
"""

from __future__ import annotations

import argparse
import ast
import email.parser
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
from typing import Any


SCHEMA_VERSION = 1
REPORT_VERSION = 1
REQUIRED_CONFIG = (
    "developerDirectory",
    "signingConfig",
    "signingIdentity",
    "pythonRoot",
    "sa3SitePackages",
    "mrt2SitePackages",
    "videoSitePackages",
    "tokenizerDirectory",
    "sourcePackagesTemplate",
)
ENGINE_NAMES = ("AudioEngine.dengine", "MRT2MusicEngine.dengine", "VideoEngine.dengine")
SUPERVISOR_ENVIRONMENT_KEY = "D_BUILD_DEVELOPMENT_SUPERVISOR_PID"
GROUP_TERM_GRACE_SECONDS = 1.0
GROUP_KILL_GRACE_SECONDS = 1.0
SOURCE_SNAPSHOT_MAXIMUM_FILES = 20_000
SOURCE_SNAPSHOT_MAXIMUM_BYTES = 1024 * 1024 * 1024
NETWORK_RESTRICTING_ENVIRONMENT = {
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_ASKPASS": "/usr/bin/false",
    "SSH_ASKPASS": "/usr/bin/false",
}


class BuildError(Exception):
    """An input, orchestration, checkpoint, or report failure."""


class StageError(BuildError):
    """A child stage failed after its record was completed."""


class Cancelled(BuildError):
    """The user interrupted the active stage."""


def _safe_message(stream: Any, value: dict[str, Any]) -> bool:
    if stream is None:
        return False
    try:
        stream.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")
        stream.flush()
    except (AttributeError, BrokenPipeError, OSError, UnicodeError, ValueError):
        try:
            descriptor = stream.fileno()
            replacement = os.open(os.devnull, os.O_WRONLY)
            try:
                os.dup2(replacement, descriptor)
            finally:
                os.close(replacement)
        except (OSError, ValueError):
            pass
        return False
    return True


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _read_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BuildError(f"{label} is unreadable or malformed: {path}: {error}") from error


def _absolute(value: str, label: str) -> Path:
    if not value or "\x00" in value:
        raise BuildError(f"{label} must be a non-empty path")
    path = Path(value)
    if not path.is_absolute():
        raise BuildError(f"{label} must be absolute: {path}")
    return Path(os.path.normpath(path))


def _regular(path: Path, label: str, *, executable: bool = False) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise BuildError(f"{label} is missing or unreadable: {path}") from error
    if not stat.S_ISREG(info.st_mode):
        raise BuildError(f"{label} must be a regular non-symlink file: {path}")
    if executable and not info.st_mode & 0o111:
        raise BuildError(f"{label} must be executable: {path}")


def _directory(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise BuildError(f"{label} is missing or unreadable: {path}") from error
    if not stat.S_ISDIR(info.st_mode):
        raise BuildError(f"{label} must be a regular non-symlink directory: {path}")


def _reject_symlink_ancestors(path: Path, label: str) -> None:
    current = path
    while current != current.parent:
        if os.path.lexists(current) and current.is_symlink():
            raise BuildError(f"{label} has a symbolic-link path component: {current}")
        current = current.parent


def _same_or_inside(candidate: Path, root: Path) -> bool:
    try:
        candidate.relative_to(root)
        return True
    except ValueError:
        return False


def _overlap(left: Path, right: Path) -> bool:
    left_resolved = left.resolve(strict=False)
    right_resolved = right.resolve(strict=False)
    return _same_or_inside(left_resolved, right_resolved) or _same_or_inside(right_resolved, left_resolved)


def _command_bytes(argv: list[str], environment: dict[str, str], label: str) -> bytes:
    process: subprocess.Popen[str] | None = None
    try:
        process = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=15)
        except subprocess.TimeoutExpired as error:
            cleanup = _drain_owned_group(process, terminate_leader=True)
            for pipe in (process.stdout, process.stderr):
                if pipe is not None:
                    pipe.close()
            raise BuildError(f"{label} timed out; cleanupIncomplete={cleanup['cleanupIncomplete']}") from error
        cleanup = _drain_owned_group(process, terminate_leader=False)
        if cleanup["leftoverDetected"] or cleanup["cleanupIncomplete"]:
            raise BuildError(
                f"{label} left processes in its owned group; "
                f"cleanupIncomplete={cleanup['cleanupIncomplete']}"
            )
    except (KeyboardInterrupt, Cancelled) as error:
        if process is not None:
            cleanup = _drain_owned_group(process, terminate_leader=True)
            for pipe in (process.stdout, process.stderr):
                if pipe is not None:
                    pipe.close()
            if cleanup["cleanupIncomplete"]:
                raise Cancelled(f"cancelled while attempting to {label}; cleanupIncomplete=true") from error
        raise Cancelled(f"cancelled while attempting to {label}") from error
    except (OSError, UnicodeError) as error:
        raise BuildError(f"{label} could not run: {error}") from error
    if process.returncode != 0:
        detail = (stderr or stdout).decode("utf-8", errors="replace").strip()
        raise BuildError(f"{label} exited {process.returncode}: {detail[:500]}")
    return stdout


def _command_output(argv: list[str], environment: dict[str, str], label: str) -> str:
    return _command_bytes(argv, environment, label).decode("utf-8", errors="strict").strip()


def _load_config(path: Path) -> tuple[dict[str, str], str]:
    _regular(path, "config")
    value = _read_json(path, "config")
    if not isinstance(value, dict):
        raise BuildError("config root must be an object")
    if type(value.get("schemaVersion")) is not int or value.get("schemaVersion") != SCHEMA_VERSION:
        raise BuildError(f"config schemaVersion must be integer {SCHEMA_VERSION}")
    allowed = {"schemaVersion", *REQUIRED_CONFIG}
    unknown = sorted(set(value) - allowed)
    missing = sorted(allowed - set(value))
    if unknown or missing:
        raise BuildError(f"config fields differ from schema; missing={missing}, unknown={unknown}")
    result: dict[str, str] = {}
    for key in REQUIRED_CONFIG:
        item = value[key]
        if not isinstance(item, str) or not item:
            raise BuildError(f"config {key} must be a non-empty string")
        result[key] = item
    if re.fullmatch(r"[0-9A-Fa-f]{40}", result["signingIdentity"]) is None:
        raise BuildError("config signingIdentity must be an existing 40-character certificate fingerprint")
    return result, _sha256(path)


def _literal_constants(path: Path, names: set[str]) -> dict[str, Any]:
    _regular(path, "packaging API reference")
    try:
        module = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except (OSError, UnicodeError, SyntaxError) as error:
        raise BuildError(f"packaging API reference is unreadable: {path}: {error}") from error
    result: dict[str, Any] = {}
    for node in module.body:
        if not isinstance(node, (ast.Assign, ast.AnnAssign)):
            continue
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        value_node = node.value
        if value_node is None:
            continue
        for target in targets:
            if isinstance(target, ast.Name) and target.id in names:
                try:
                    result[target.id] = ast.literal_eval(value_node)
                except (ValueError, TypeError, SyntaxError) as error:
                    raise BuildError(f"packaging constant {target.id} is not literal in {path}") from error
    missing = sorted(names - set(result))
    if missing:
        raise BuildError(f"packaging API reference lacks constants {missing}: {path}")
    return result


def _validate_plain_tree(root: Path, label: str, *, stdlib: bool = False) -> None:
    _directory(root, label)
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        relative_current = current_path.relative_to(root)
        if stdlib:
            directories[:] = [
                name for name in directories
                if name not in {"site-packages", "__pycache__", ".git"}
            ]
        for name in directories + files:
            relative = relative_current / name
            if stdlib and (name == ".DS_Store" or relative.suffix in {".pyc", ".pyo"}):
                continue
            path = current_path / name
            try:
                info = path.lstat()
            except OSError as error:
                raise BuildError(f"{label} entry is unreadable: {path}: {error}") from error
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise BuildError(f"{label} contains a link or special file: {path}")


def _metadata_identity(path: Path, label: str) -> tuple[str, str]:
    metadata = path / "METADATA"
    _regular(metadata, f"{label} METADATA")
    try:
        parsed = email.parser.Parser().parsestr(metadata.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as error:
        raise BuildError(f"{label} METADATA is unreadable: {error}") from error
    name, version = parsed.get("Name"), parsed.get("Version")
    if not name or not version:
        raise BuildError(f"{label} METADATA lacks Name or Version")
    return name, version


def _normalized_distribution(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def _validate_packaging_inputs(paths: dict[str, Path], source_root: Path) -> None:
    audio_packaging = source_root / "Backends/Audio/Packaging"
    video_packaging = source_root / "Backends/Video/Packaging"
    audio_api = _literal_constants(
        audio_packaging / "prepare_engine.py", {"REQUIRED_PACKAGES", "REQUIRED_DISTRIBUTIONS"},
    )
    mrt_api = _literal_constants(
        audio_packaging / "prepare_mrt2_engine.py", {"DISTRIBUTIONS", "PACKAGES", "PROVIDERS"},
    )
    video_api = _literal_constants(
        video_packaging / "prepare_video_engine.py",
        {
            "TOKENIZER_DIGESTS", "REQUIRED_DISTRIBUTIONS", "REQUIRED_PACKAGES",
            "VIDEO_SCRIPTS", "MODEL_DECLARATION", "TOKENIZERS_LICENSE_SHA256",
        },
    )

    interpreter = paths["pythonRoot"] / "bin/python3.12"
    stdlib = paths["pythonRoot"] / "lib/python3.12"
    _regular(interpreter, "packaged Python 3.12 interpreter", executable=True)
    _regular(stdlib / "LICENSE.txt", "packaged Python stdlib license")
    _regular(stdlib / "encodings/__init__.py", "packaged Python encodings module")
    _validate_plain_tree(stdlib, "packaged Python stdlib", stdlib=True)

    sa3 = paths["sa3SitePackages"]
    _validate_plain_tree(sa3, "SA3 site-packages")
    sa3_entries = list(sa3.iterdir())
    for name in audio_api["REQUIRED_PACKAGES"]:
        _directory(sa3 / name, f"SA3 package {name}")
    for name in audio_api["REQUIRED_DISTRIBUTIONS"]:
        normalized = name.replace("_", "-")
        matches = [
            entry for entry in sa3_entries
            if entry.name.endswith(".dist-info")
            and (entry.name.startswith(name + "-") or entry.name.startswith(normalized + "-"))
            and entry.is_dir() and not entry.is_symlink()
        ]
        if not matches:
            raise BuildError(f"SA3 site-packages lacks distribution metadata for {name}")
    sa3_packages = set(audio_api["REQUIRED_PACKAGES"])
    sa3_distributions = set(audio_api["REQUIRED_DISTRIBUTIONS"])
    for entry in sa3_entries:
        permitted = (
            entry.name in sa3_packages
            or entry.name == "mlx_metal"
            or entry.name.endswith(".libs") and entry.name[:-5] in sa3_packages
            or entry.name in {"pip", "_distutils_hack", "distutils-precedence.pth"}
            or entry.name.startswith("pip-") and entry.name.endswith(".dist-info")
            or entry.name.startswith("setuptools")
            or any(
                entry.name.endswith(".dist-info")
                and (
                    entry.name.startswith(name + "-")
                    or entry.name.startswith(name.replace("_", "-") + "-")
                )
                for name in sa3_distributions
            )
        )
        if not permitted:
            raise BuildError(f"SA3 site-packages contains an unapproved component: {entry.name}")
        if (
            entry.name == "mlx_metal"
            or entry.name.endswith(".libs") and entry.name[:-5] in sa3_packages
        ) and (entry.is_symlink() or not entry.is_dir()):
            raise BuildError(f"SA3 native component must be a regular directory: {entry.name}")

    mrt = paths["mrt2SitePackages"]
    _validate_plain_tree(mrt, "MRT2 site-packages")
    for name in mrt_api["PACKAGES"]:
        _directory(mrt / name, f"MRT2 package {name}")
    for name, version in mrt_api["DISTRIBUTIONS"].items():
        distribution = mrt / f"{name}-{version}.dist-info"
        _directory(distribution, f"MRT2 distribution {name}")
        actual_name, actual_version = _metadata_identity(distribution, f"MRT2 distribution {name}")
        if actual_name.replace("-", "_").lower() != name or actual_version != version:
            raise BuildError(f"MRT2 distribution identity mismatch for {name}")
    for name in (*mrt_api["PACKAGES"], "mlx_metal"):
        candidates = (mrt / f"{name}.libs",) if name != "mlx_metal" else (mrt / name,)
        for candidate in candidates:
            if os.path.lexists(candidate):
                _directory(candidate, f"MRT2 native component {candidate.name}")

    video = paths["videoSitePackages"]
    _validate_plain_tree(video, "video site-packages")
    video_entries = list(video.iterdir())
    for name in video_api["REQUIRED_PACKAGES"]:
        _directory(video / name, f"video package {name}")
        native = video / f"{name}.libs"
        if os.path.lexists(native):
            _directory(native, f"video native component {native.name}")
    optional_metal = video / "mlx_metal"
    if os.path.lexists(optional_metal):
        _directory(optional_metal, "video package mlx_metal")
    for name, version in video_api["REQUIRED_DISTRIBUTIONS"].items():
        matches: list[Path] = []
        for entry in video_entries:
            if not entry.name.endswith(".dist-info") or entry.is_symlink() or not entry.is_dir():
                continue
            actual_name, actual_version = _metadata_identity(entry, f"video distribution {entry.name}")
            if _normalized_distribution(actual_name) == _normalized_distribution(name):
                if actual_version != version:
                    raise BuildError(f"video distribution {name} must be {version}, found {actual_version}")
                matches.append(entry)
        if len(matches) != 1:
            raise BuildError(f"video site-packages must contain exactly one {name} {version} distribution")
        licenses = [
            item for item in matches[0].rglob("*")
            if item.is_file() and not item.is_symlink()
            and item.name.lower().startswith(("license", "copying", "notice"))
        ]
        if not licenses:
            bundled_license = video_packaging / "Licenses/tokenizers-0.22.2-LICENSE.txt"
            tokenizers_exception = (
                name == "tokenizers"
                and version == "0.22.2"
                and not bundled_license.is_symlink()
                and bundled_license.is_file()
                and _sha256(bundled_license) == video_api["TOKENIZERS_LICENSE_SHA256"]
            )
            if not tokenizers_exception:
                raise BuildError(f"video distribution {name} lacks license material")

    tokenizer_digests = video_api["TOKENIZER_DIGESTS"]
    if not isinstance(tokenizer_digests, dict) or not tokenizer_digests:
        raise BuildError("video tokenizer digest contract is invalid")
    for name, expected in tokenizer_digests.items():
        path = paths["tokenizerDirectory"] / name
        _regular(path, f"tokenizer file {name}")
        if not isinstance(expected, str) or _sha256(path) != expected:
            raise BuildError(f"tokenizer file differs from the pinned revision: {name}")

    audio_provider = source_root / "Backends/Audio/Python"
    _validate_plain_tree(audio_provider, "audio provider source")
    for name in {
        "d_audio_backend.py", "d_audio_contract.py", "d_audio_sa3.py", *mrt_api["PROVIDERS"],
    }:
        _regular(audio_provider / name, f"audio provider {name}")
    _validate_plain_tree(source_root / "Vendor/stable-audio3-mlx", "SA3 vendor")
    _validate_plain_tree(source_root / "Backends/Audio/MRT2Vendor", "MRT2 vendor")
    audio_models = source_root / "Backends/Audio/Models"
    _validate_plain_tree(audio_models, "audio model declarations")
    _regular(audio_models / "mrt2-small.json", "MRT2 model declaration")
    video_root = source_root / "Backends/Video"
    _validate_plain_tree(video_root / "Python", "video provider source")
    for name in video_api["VIDEO_SCRIPTS"]:
        _regular(video_root / "Python" / name, f"video provider {name}")
    _validate_plain_tree(video_root / "Vendor/wan21", "Wan video vendor")
    declaration = video_root / "Models" / video_api["MODEL_DECLARATION"]
    _regular(declaration, "video model declaration")
    expected_declaration = {
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
    if _read_json(declaration, "video model declaration") != expected_declaration:
        raise BuildError("video model declaration differs from the fixed Wan2.1 profile")


def _package_lock(source_root: Path) -> tuple[Path, list[tuple[str, str]]]:
    path = source_root / "D.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    _regular(path, "workspace Package.resolved")
    value = _read_json(path, "workspace Package.resolved")
    if not isinstance(value, dict) or not isinstance(value.get("pins"), list):
        raise BuildError("workspace Package.resolved has invalid structure")
    pins: list[tuple[str, str]] = []
    for item in value["pins"]:
        if not isinstance(item, dict) or not isinstance(item.get("identity"), str):
            raise BuildError("workspace Package.resolved contains an invalid pin")
        state = item.get("state")
        revision = state.get("revision") if isinstance(state, dict) else None
        if not isinstance(revision, str) or re.fullmatch(r"[0-9A-Fa-f]{40}", revision) is None:
            raise BuildError(f"workspace Package.resolved pin lacks a fixed revision: {item.get('identity')}")
        pins.append((item["identity"], revision.lower()))
    if not pins or len({identity.casefold() for identity, _revision in pins}) != len(pins):
        raise BuildError("workspace Package.resolved pins are empty or duplicated")
    return path, pins


def _validate_copy_tree(root: Path, label: str) -> None:
    """Reject special files and links that cannot remain internal after copying."""
    _directory(root, label)
    resolved_root = root.resolve(strict=True)
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in directories + files:
            path = current_path / name
            try:
                info = path.lstat()
            except OSError as error:
                raise BuildError(f"{label} entry is unreadable: {path}: {error}") from error
            if stat.S_ISLNK(info.st_mode):
                try:
                    target = os.readlink(path)
                    if os.path.isabs(target):
                        raise BuildError(f"{label} contains an absolute symbolic link: {path}")
                    resolved = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise BuildError(f"{label} contains a broken symbolic link: {path}: {error}") from error
                if not _same_or_inside(resolved, resolved_root):
                    raise BuildError(f"{label} symbolic link escapes its root: {path}")
            elif not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise BuildError(f"{label} contains a special file: {path}")


def _git_storage_path(checkout: Path, value: str, label: str) -> Path:
    if not value or "\x00" in value:
        raise BuildError(f"{label} returned an invalid path")
    supplied = Path(value)
    path = supplied if supplied.is_absolute() else checkout / supplied
    try:
        return path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise BuildError(f"{label} path cannot be resolved: {path}: {error}") from error


def _validate_git_storage(
    checkout: Path,
    template: Path,
    git: Path,
    environment: dict[str, str],
    label: str,
) -> None:
    dot_git = checkout / ".git"
    _directory(dot_git, f"{label} .git")
    resolved_dot_git = dot_git.resolve(strict=True)
    for argument, storage_label in (("--git-dir", "git-dir"), ("--git-common-dir", "git-common-dir")):
        value = _command_output(
            [str(git), "-C", str(checkout), "rev-parse", argument],
            environment,
            f"read {label} {storage_label}",
        )
        resolved = _git_storage_path(checkout, value, f"{label} {storage_label}")
        if not _same_or_inside(resolved, resolved_dot_git):
            raise BuildError(f"{label} {storage_label} escapes its private .git directory: {resolved}")

    alternates = resolved_dot_git / "objects/info/alternates"
    if os.path.lexists(alternates):
        _regular(alternates, f"{label} object alternates")
        try:
            lines = alternates.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as error:
            raise BuildError(f"{label} object alternates are unreadable: {error}") from error
        if not lines:
            raise BuildError(f"{label} object alternates file is empty")
        template_root = template.resolve(strict=True)
        for line in lines:
            if not line or "\x00" in line:
                raise BuildError(f"{label} object alternates contain an invalid path")
            candidate = Path(line)
            if not candidate.is_absolute():
                # Git resolves relative alternates from the object database,
                # not from objects/info where the alternates file lives.
                candidate = resolved_dot_git / "objects" / candidate
            try:
                resolved = candidate.resolve(strict=True)
            except (OSError, RuntimeError) as error:
                raise BuildError(f"{label} object alternate is broken: {candidate}: {error}") from error
            if not _same_or_inside(resolved, template_root):
                raise BuildError(f"{label} object alternate escapes SourcePackages: {resolved}")


def _verify_checkouts(
    template: Path,
    pins: list[tuple[str, str]],
    git: Path,
    environment: dict[str, str],
    label: str,
) -> dict[str, str]:
    checkouts = template / "checkouts"
    _directory(checkouts, f"{label} checkouts")
    actual: dict[str, Path] = {}
    try:
        entries = list(checkouts.iterdir())
    except OSError as error:
        raise BuildError(f"{label} checkouts are unreadable: {error}") from error
    for entry in entries:
        if entry.name.casefold() in actual:
            raise BuildError(f"{label} has case-fold duplicate checkout: {entry.name}")
        actual[entry.name.casefold()] = entry
    expected_names = {identity.casefold() for identity, _revision in pins}
    if set(actual) != expected_names:
        unexpected = sorted(entry.name for key, entry in actual.items() if key not in expected_names)
        raise BuildError(f"{label} contains unlocked checkouts: {unexpected}")
    revisions: dict[str, str] = {}
    for identity, expected in pins:
        checkout = actual.get(identity.casefold())
        if checkout is None:
            raise BuildError(f"{label} lacks locked checkout: {identity}")
        _directory(checkout, f"{label} checkout {identity}")
        _validate_git_storage(checkout, template, git, environment, f"{label} checkout {identity}")
        observed = _command_output(
            [str(git), "-C", str(checkout), "rev-parse", "HEAD"],
            environment,
            f"read {label} checkout revision for {identity}",
        ).lower()
        if observed != expected:
            raise BuildError(f"{label} checkout {identity} is {observed}, expected {expected}")
        dirty = _command_bytes(
            [str(git), "-C", str(checkout), "status", "--porcelain=v1", "-z", "--untracked-files=all"],
            environment,
            f"read {label} checkout cleanliness for {identity}",
        )
        if dirty:
            raise BuildError(f"{label} checkout {identity} is not clean")
        revisions[identity] = observed
    return revisions


def _nul_paths(value: bytes, label: str) -> list[bytes]:
    if value and not value.endswith(b"\0"):
        raise BuildError(f"{label} did not return a NUL-terminated path list")
    paths = value.split(b"\0")[:-1] if value else []
    if len(paths) > SOURCE_SNAPSHOT_MAXIMUM_FILES:
        raise BuildError(f"{label} exceeds the {SOURCE_SNAPSHOT_MAXIMUM_FILES} file limit")
    if any(not path for path in paths):
        raise BuildError(f"{label} returned an empty path")
    return paths


def _content_snapshot(source_root: Path, raw_paths: list[bytes], label: str) -> dict[str, Any]:
    digest = hashlib.sha256()
    total = 0
    for raw in sorted(raw_paths):
        relative_text = os.fsdecode(raw)
        relative = Path(relative_text)
        if relative.is_absolute() or not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
            raise BuildError(f"{label} returned an unsafe source path: {relative_text!r}")
        path = source_root / relative
        current = source_root
        for part in relative.parts[:-1]:
            current /= part
            if current.is_symlink():
                raise BuildError(f"{label} path traverses a source symlink: {relative_text!r}")
        digest.update(len(raw).to_bytes(8, "big"))
        digest.update(raw)
        if not os.path.lexists(path):
            digest.update(b"D")
            continue
        try:
            info = path.lstat()
        except OSError as error:
            raise BuildError(f"{label} source path is unreadable: {path}: {error}") from error
        digest.update(stat.S_IMODE(info.st_mode).to_bytes(4, "big"))
        if stat.S_ISLNK(info.st_mode):
            payload = os.fsencode(os.readlink(path))
            digest.update(b"L")
            digest.update(len(payload).to_bytes(8, "big"))
            digest.update(payload)
            total += len(payload)
        elif stat.S_ISREG(info.st_mode):
            digest.update(b"F")
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    total += len(block)
                    if total > SOURCE_SNAPSHOT_MAXIMUM_BYTES:
                        raise BuildError(
                            f"{label} exceeds the {SOURCE_SNAPSHOT_MAXIMUM_BYTES} byte limit"
                        )
                    digest.update(block)
        else:
            raise BuildError(f"{label} source path is not a regular file or symlink: {path}")
    return {"sha256": digest.hexdigest(), "fileCount": len(raw_paths), "contentBytes": total}


def _source_snapshot(
    source_root: Path,
    git: Path,
    environment: dict[str, str],
) -> tuple[dict[str, Any], list[str]]:
    prefix = [str(git), "-C", str(source_root)]
    status = _command_bytes(
        [*prefix, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        environment,
        "read source status",
    )
    index = _command_bytes(
        [*prefix, "ls-files", "-s", "-z"], environment, "read source index",
    )
    changed_raw = _command_bytes(
        [*prefix, "diff", "--name-only", "-z", "--no-ext-diff"],
        environment,
        "read changed tracked paths",
    )
    untracked_raw = _command_bytes(
        [*prefix, "ls-files", "--others", "--exclude-standard", "-z"],
        environment,
        "read untracked source paths",
    )
    changed = _nul_paths(changed_raw, "changed tracked paths")
    untracked = _nul_paths(untracked_raw, "untracked source paths")
    working = _content_snapshot(source_root, changed, "changed tracked content")
    snapshot = {
        "statusSha256": hashlib.sha256(status).hexdigest(),
        "indexSha256": hashlib.sha256(index).hexdigest(),
        "workingDiffSha256": working["sha256"],
        "workingTracked": working,
        "untracked": _content_snapshot(source_root, untracked, "untracked content"),
    }
    display = [os.fsdecode(item) for item in status.split(b"\0") if item]
    return snapshot, display


def _stat_identity(path: Path) -> dict[str, int]:
    info = path.lstat()
    return {
        "device": info.st_dev,
        "inode": info.st_ino,
        "mode": stat.S_IMODE(info.st_mode),
        "size": info.st_size,
        "mtimeNs": info.st_mtime_ns,
        "ctimeNs": info.st_ctime_ns,
    }


def _protected_snapshot(paths: dict[str, Path], lock_path: Path) -> dict[str, Any]:
    return {
        "files": {
            "config": _sha256(paths["config"]),
            "signingConfig": _sha256(paths["signingConfig"]),
            "packageResolved": _sha256(lock_path),
        },
        "roots": {
            key: _stat_identity(paths[key])
            for key in (
                "pythonRoot", "sa3SitePackages", "mrt2SitePackages",
                "videoSitePackages", "tokenizerDirectory", "sourcePackagesTemplate",
            )
        },
    }


def _preflight(config_path: Path, run_root: Path) -> dict[str, Any]:
    if sys.version_info[:2] != (3, 12):
        raise BuildError(f"Python 3.12 is required, found {sys.version.split()[0]}")
    _reject_symlink_ancestors(config_path, "config")
    config, config_digest = _load_config(config_path)
    source_root = Path(__file__).resolve().parents[1]
    paths: dict[str, Path] = {"config": config_path, "sourceRoot": source_root}
    for key in REQUIRED_CONFIG:
        if key != "signingIdentity":
            paths[key] = _absolute(config[key], f"config {key}")

    _directory(paths["developerDirectory"], "developerDirectory")
    _regular(paths["signingConfig"], "signingConfig")
    for key in (
        "pythonRoot", "sa3SitePackages", "mrt2SitePackages", "videoSitePackages",
        "tokenizerDirectory", "sourcePackagesTemplate",
    ):
        _directory(paths[key], key)
    for key, path in paths.items():
        if key != "sourceRoot":
            _reject_symlink_ancestors(path, key)

    if os.path.lexists(run_root):
        raise BuildError(f"run-root already exists; refusing to overwrite or clean: {run_root}")
    parent = run_root.parent
    _directory(parent, "run-root parent")
    _reject_symlink_ancestors(parent, "run-root parent")
    for key, path in paths.items():
        if _overlap(run_root, path):
            raise BuildError(f"run-root overlaps {key}: {path}")

    scripts = {
        "build-local": source_root / "scripts/build-local.sh",
        "package-audio": source_root / "Backends/Audio/Packaging/package_audio_app.py",
        "prepare-video": source_root / "Backends/Video/Packaging/prepare_video_engine.py",
        "package-video": source_root / "Backends/Video/Packaging/package_video_app.py",
    }
    for label, path in scripts.items():
        _regular(path, label, executable=label == "build-local")
    _directory(source_root / "Backends/Video", "video source root")
    _directory(source_root / "Backends/Audio/Python", "audio provider source")
    _validate_packaging_inputs(paths, source_root)

    tools = {
        "git": paths["developerDirectory"] / "usr/bin/git",
        "xcodebuild": paths["developerDirectory"] / "usr/bin/xcodebuild",
        "bash": Path("/bin/bash"),
        "codesign": Path("/usr/bin/codesign"),
        "python": Path(sys.executable).resolve(strict=True),
    }
    for label, path in tools.items():
        _regular(path, label, executable=True)

    environment = os.environ.copy()
    environment.update(NETWORK_RESTRICTING_ENVIRONMENT)
    lock_path, pins = _package_lock(source_root)
    _validate_copy_tree(paths["sourcePackagesTemplate"], "sourcePackagesTemplate")
    checkout_revisions = _verify_checkouts(
        paths["sourcePackagesTemplate"], pins, tools["git"], environment, "sourcePackagesTemplate",
    )
    source_head = _command_output(
        [str(tools["git"]), "-C", str(source_root), "rev-parse", "HEAD"], environment, "read source HEAD",
    )
    if re.fullmatch(r"[0-9A-Fa-f]{40}", source_head) is None:
        raise BuildError(f"source HEAD is not a full commit identifier: {source_head}")
    source_snapshot, source_changes = _source_snapshot(source_root, tools["git"], environment)
    versions = {
        "python": sys.version.split()[0],
        "git": _command_output([str(tools["git"]), "--version"], environment, "read Git version"),
        "xcodebuild": _command_output([str(tools["xcodebuild"]), "-version"], environment, "read Xcode version"),
    }
    return {
        "config": config,
        "configDigest": config_digest,
        "paths": paths,
        "scripts": scripts,
        "tools": tools,
        "environment": environment,
        "lockPath": lock_path,
        "pins": pins,
        "checkoutRevisions": checkout_revisions,
        "sourceHead": source_head.lower(),
        "sourceChanges": source_changes,
        "sourceSnapshot": source_snapshot,
        "toolVersions": versions,
    }


def _group_exists(group: int) -> bool:
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _wait_for_group_exit(group: int, seconds: float, process: subprocess.Popen[Any]) -> bool:
    deadline = time.monotonic() + seconds
    while _group_exists(group):
        process.poll()
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)
    return True


def _drain_owned_group(process: subprocess.Popen[Any], *, terminate_leader: bool) -> dict[str, Any]:
    """Drain only the session/process group created for this known child."""
    previous: dict[int, Any] = {}
    for number in (signal.SIGINT, signal.SIGTERM):
        try:
            previous[number] = signal.getsignal(number)
            signal.signal(number, signal.SIG_IGN)
        except ValueError:
            pass

    group = process.pid
    leader_was_running = process.poll() is None
    leftover = not leader_was_running and _group_exists(group)
    sent: int | None = None
    incomplete = False
    error: str | None = None
    try:
        if (terminate_leader or leftover) and _group_exists(group):
            try:
                os.killpg(group, signal.SIGTERM)
                sent = signal.SIGTERM
            except ProcessLookupError:
                pass
            except PermissionError as signal_error:
                incomplete = True
                error = f"TERM refused for owned group {group}: {signal_error}"
            if not incomplete and not _wait_for_group_exit(group, GROUP_TERM_GRACE_SECONDS, process):
                try:
                    os.killpg(group, signal.SIGKILL)
                    sent = signal.SIGKILL
                except ProcessLookupError:
                    pass
                except PermissionError as signal_error:
                    incomplete = True
                    error = f"KILL refused for owned group {group}: {signal_error}"
                if not incomplete and not _wait_for_group_exit(group, GROUP_KILL_GRACE_SECONDS, process):
                    incomplete = True
                    error = f"owned group {group} still exists after KILL deadline"
        try:
            process.wait(timeout=GROUP_TERM_GRACE_SECONDS + GROUP_KILL_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            incomplete = True
            error = error or f"owned leader {process.pid} was not reaped before deadline"
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    return {
        "returnCode": process.returncode,
        "terminationSignal": sent,
        "leftoverDetected": leftover,
        "cleanupIncomplete": incomplete,
        "cleanupError": error,
    }


def _run_stage(
    name: str,
    argv: list[str],
    environment: dict[str, str],
    log_path: Path,
    timeout: float,
    stages: list[dict[str, Any]],
) -> None:
    started = time.monotonic()
    record: dict[str, Any] = {
        "name": name,
        "command": argv,
        "status": "running",
        "log": str(log_path),
        "timeoutSeconds": timeout,
    }
    stages.append(record)
    process: subprocess.Popen[Any] | None = None
    try:
        with log_path.open("xb") as log:
            process = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                env=environment,
            )
            try:
                return_code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired as error:
                cleanup = _drain_owned_group(process, terminate_leader=True)
                record.update(
                    status="timed-out",
                    returnCode=cleanup["returnCode"],
                    terminationSignal=cleanup["terminationSignal"],
                    cleanupIncomplete=cleanup["cleanupIncomplete"],
                )
                if cleanup["cleanupError"]:
                    record["cleanupError"] = cleanup["cleanupError"]
                raise StageError(
                    f"{name} timed out after {timeout:g}s; "
                    f"cleanupIncomplete={cleanup['cleanupIncomplete']}"
                ) from error
            cleanup = _drain_owned_group(process, terminate_leader=False)
            record["returnCode"] = return_code
            record["leftoverDetected"] = cleanup["leftoverDetected"]
            record["cleanupIncomplete"] = cleanup["cleanupIncomplete"]
            if cleanup["terminationSignal"] is not None:
                record["terminationSignal"] = cleanup["terminationSignal"]
            if cleanup["cleanupError"]:
                record["cleanupError"] = cleanup["cleanupError"]
            if return_code < 0:
                record["terminationSignal"] = -return_code
            if cleanup["leftoverDetected"] or cleanup["cleanupIncomplete"]:
                record["status"] = "abnormal-leftover"
                raise StageError(
                    f"{name} left processes in its owned group; "
                    f"cleanupIncomplete={cleanup['cleanupIncomplete']}"
                )
            if return_code != 0:
                record["status"] = "failed"
                raise StageError(f"{name} exited {return_code}; see {log_path}")
            record["status"] = "succeeded"
    except (KeyboardInterrupt, Cancelled) as error:
        if process is not None:
            cleanup = _drain_owned_group(process, terminate_leader=True)
            record.update(
                status="cancelled",
                returnCode=cleanup["returnCode"],
                terminationSignal=cleanup["terminationSignal"],
                cleanupIncomplete=cleanup["cleanupIncomplete"],
            )
            if cleanup["cleanupError"]:
                record["cleanupError"] = cleanup["cleanupError"]
        else:
            record["status"] = "cancelled"
        suffix = "; cleanupIncomplete=true" if record.get("cleanupIncomplete") else ""
        raise Cancelled(f"cancelled during {name}{suffix}") from error
    except OSError as error:
        record["status"] = "failed-to-start"
        record["error"] = str(error)
        raise StageError(f"{name} could not start: {error}") from error
    finally:
        record["durationSeconds"] = round(time.monotonic() - started, 6)


def _checkpoint_directory(path: Path, label: str) -> None:
    _directory(path, label)


def _manifest_summary(path: Path) -> dict[str, Any]:
    _regular(path, "engine manifest")
    if path.stat().st_size > 4 * 1024 * 1024:
        raise BuildError(f"engine manifest exceeds 4 MiB: {path}")
    value = _read_json(path, "engine manifest")
    if not isinstance(value, dict) or not isinstance(value.get("files"), list):
        raise BuildError(f"engine manifest has invalid structure: {path}")
    return {
        "path": str(path),
        "sha256": _sha256(path),
        "schemaVersion": value.get("schemaVersion"),
        "kind": value.get("kind"),
        "fileCount": len(value["files"]),
    }


def _last_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise BuildError(f"{label} log is unreadable: {path}: {error}") from error
    for line in reversed(lines):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise BuildError(f"{label} did not emit its JSON package report: {path}")


def _json_report(path: Path, label: str) -> dict[str, Any]:
    value = _read_json(path, label)
    if not isinstance(value, dict):
        raise BuildError(f"{label} root must be an object: {path}")
    return value


def _write_report_exclusive(path: Path, value: dict[str, Any]) -> None:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode("utf-8") + b"\n"
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError as error:
        raise BuildError(f"report path is not new or writable: {path}: {error}") from error
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except (OSError, ValueError) as error:
        try:
            path.unlink()
        except OSError:
            pass
        raise BuildError(f"report write/flush/fsync failed: {path}: {error}") from error
    try:
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except OSError as error:
        raise BuildError(f"report was published but directory synchronization failed: {path}: {error}") from error


def _base_report(preflight: dict[str, Any], config_path: Path, run_root: Path) -> dict[str, Any]:
    config = preflight["config"]
    summarized_config = {
        key: config[key]
        for key in REQUIRED_CONFIG
        if key != "signingIdentity"
    }
    summarized_config["signingIdentity"] = config["signingIdentity"]
    return {
        "schemaVersion": REPORT_VERSION,
        "task": "D-MB-BUILD-01",
        "specRevision": 3,
        "contract": "MB-BUILD2",
        "status": "running",
        "runtimeVerification": "not-run",
        "source": {
            "root": str(preflight["paths"]["sourceRoot"]),
            "head": preflight["sourceHead"],
            "uncommittedChanges": preflight["sourceChanges"],
            "snapshot": preflight["sourceSnapshot"],
        },
        "config": {
            "path": str(config_path),
            "sha256": preflight["configDigest"],
            "schemaVersion": SCHEMA_VERSION,
            "values": summarized_config,
        },
        "runRoot": str(run_root),
        "toolVersions": preflight["toolVersions"],
        "swiftPackageCheckouts": preflight["checkoutRevisions"],
        "networkControl": "Git prompts/config updates disabled and Xcode offline flags requested; not a claim of system network isolation",
        "stages": [],
        "packageReports": {},
        "engineManifests": {},
    }


def _execute(preflight: dict[str, Any], config_path: Path, run_root: Path, timeout: float) -> tuple[dict[str, Any], Path]:
    paths = preflight["paths"]
    config = preflight["config"]
    try:
        run_root.mkdir(mode=0o700)
        directories = {
            name: run_root / name
            for name in ("artifacts", "cache", "evidence", "logs", "output", "tmp")
        }
        for directory in directories.values():
            directory.mkdir(mode=0o700)
    except OSError as error:
        raise BuildError(f"could not create isolated run directories: {error}") from error

    report_path = directories["evidence"] / "build-development-report.json"
    report = _base_report(preflight, config_path, run_root)
    before = _protected_snapshot(paths, preflight["lockPath"])

    source_packages = directories["cache"] / "SourcePackages-App"
    try:
        shutil.copytree(paths["sourcePackagesTemplate"], source_packages, symlinks=True, copy_function=shutil.copy2)
    except (OSError, shutil.Error) as error:
        report.update(status="failed", error=f"copy isolated SwiftPM template: {error}")
        _write_report_exclusive(report_path, report)
        raise BuildError(report["error"]) from error
    try:
        _validate_copy_tree(paths["sourcePackagesTemplate"], "sourcePackagesTemplate after copy")
        source_revisions = _verify_checkouts(
            paths["sourcePackagesTemplate"],
            preflight["pins"],
            preflight["tools"]["git"],
            preflight["environment"],
            "sourcePackagesTemplate after copy",
        )
        if source_revisions != preflight["checkoutRevisions"]:
            raise BuildError("sourcePackagesTemplate checkout revisions changed during copy")
        _validate_copy_tree(source_packages, "isolated SourcePackages")
        _verify_checkouts(
            source_packages,
            preflight["pins"],
            preflight["tools"]["git"],
            preflight["environment"],
            "isolated SourcePackages",
        )
    except (BuildError, OSError, shutil.Error, UnicodeError) as caught:
        error = caught if isinstance(caught, BuildError) else BuildError(
            f"packaging orchestration I/O failure: {caught}"
        )
        report.update(status="failed", error=str(error))
        _write_report_exclusive(report_path, report)
        raise error

    derived_data = directories["cache"] / "DerivedData"
    cache_paths = {
        "clang": directories["cache"] / "ClangModuleCache",
        "swift": directories["cache"] / "SwiftModuleCache",
        "python": directories["cache"] / "PythonCache",
    }
    for path in (derived_data, *cache_paths.values()):
        path.mkdir()
    environment = preflight["environment"].copy()
    environment.update({
        "DEVELOPER_DIR": str(paths["developerDirectory"]),
        "D_DEVELOPMENT_ROOT": str(run_root),
        "D_SIGNING_CONFIG": str(paths["signingConfig"]),
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONPYCACHEPREFIX": str(cache_paths["python"]),
        "TMPDIR": str(directories["tmp"]) + "/",
        "CLANG_MODULE_CACHE_PATH": str(cache_paths["clang"]),
        "SWIFT_MODULE_CACHE_PATH": str(cache_paths["swift"]),
        "MODULE_CACHE_DIR": str(cache_paths["clang"]),
        SUPERVISOR_ENVIRONMENT_KEY: str(os.getpid()),
        "PATH": ":".join((
            str(paths["developerDirectory"] / "usr/bin"),
            str(Path(sys.executable).parent),
            "/usr/bin", "/bin",
        )),
    })

    stages: list[dict[str, Any]] = report["stages"]
    built_app = derived_data / "Build/Products/Debug/D.app"
    audio_app = directories["artifacts"] / "D Audio.app"
    video_engine = directories["artifacts"] / "VideoEngine.dengine"
    final_app = directories["output"] / "D Development.app"
    video_package_report = directories["evidence"] / "package-video-report.json"
    stage_plan = (
        (
            "build-local",
            [
                "/bin/bash", str(preflight["scripts"]["build-local"]),
                "--derived-data-path", str(derived_data),
                "--source-packages-path", str(source_packages),
                "--log-path", str(directories["logs"] / "build-local-xcode.log"),
                "--offline",
            ],
            directories["logs"] / "01-build-local.log",
        ),
        (
            "package-audio-app",
            [
                str(preflight["tools"]["python"]), "-B", str(preflight["scripts"]["package-audio"]),
                "--app", str(built_app),
                "--python-root", str(paths["pythonRoot"]),
                "--sa3-site-packages", str(paths["sa3SitePackages"]),
                "--mrt2-site-packages", str(paths["mrt2SitePackages"]),
                "--identity", config["signingIdentity"],
                "--output", str(audio_app),
            ],
            directories["logs"] / "02-package-audio.log",
        ),
        (
            "prepare-video-engine",
            [
                str(preflight["tools"]["python"]), "-B", str(preflight["scripts"]["prepare-video"]),
                "--python-root", str(paths["pythonRoot"]),
                "--site-packages", str(paths["videoSitePackages"]),
                "--video-root", str(paths["sourceRoot"] / "Backends/Video"),
                "--audio-provider-directory", str(paths["sourceRoot"] / "Backends/Audio/Python"),
                "--tokenizer", str(paths["tokenizerDirectory"]),
                "--output", str(video_engine),
            ],
            directories["logs"] / "03-prepare-video.log",
        ),
        (
            "package-video-app",
            [
                str(preflight["tools"]["python"]), "-B", str(preflight["scripts"]["package-video"]),
                "--app", str(audio_app),
                "--engine", str(video_engine),
                "--identity", config["signingIdentity"],
                "--output", str(final_app),
                "--report", str(video_package_report),
            ],
            directories["logs"] / "04-package-video.log",
        ),
    )

    try:
        for index, (name, argv, log_path) in enumerate(stage_plan):
            _run_stage(name, argv, environment, log_path, timeout, stages)
            if index == 0:
                _checkpoint_directory(built_app, "build-local output App")
            elif index == 1:
                _checkpoint_directory(audio_app, "audio package output App")
                report["packageReports"]["audio"] = _last_json_object(log_path, "audio package")
                for engine in ENGINE_NAMES[:2]:
                    report["engineManifests"][engine] = _manifest_summary(
                        audio_app / "Contents/Resources" / engine / "engine.json"
                    )
            elif index == 2:
                _checkpoint_directory(video_engine, "prepared video engine")
                report["engineManifests"][ENGINE_NAMES[2]] = _manifest_summary(video_engine / "engine.json")
            else:
                _checkpoint_directory(final_app, "final packaged App")
                report["packageReports"]["video"] = _json_report(video_package_report, "video package report")
                final_manifests: dict[str, Any] = {}
                for engine in ENGINE_NAMES:
                    final_manifests[engine] = _manifest_summary(
                        final_app / "Contents/Resources" / engine / "engine.json"
                    )
                report["engineManifests"] = final_manifests

        after = _protected_snapshot(paths, preflight["lockPath"])
        if after != before:
            raise BuildError("a protected config, lock, or input root changed during packaging")
        final_head = _command_output(
            [str(preflight["tools"]["git"]), "-C", str(paths["sourceRoot"]), "rev-parse", "HEAD"],
            preflight["environment"],
            "re-read source HEAD",
        ).lower()
        final_snapshot, final_changes = _source_snapshot(
            paths["sourceRoot"], preflight["tools"]["git"], preflight["environment"],
        )
        report["source"]["finalSnapshot"] = final_snapshot
        if (
            final_head != preflight["sourceHead"]
            or final_changes != preflight["sourceChanges"]
            or final_snapshot != preflight["sourceSnapshot"]
        ):
            raise BuildError("source HEAD, status, index, or dirty content changed during packaging")
        if report["packageReports"]["video"].get("status") != "packaged":
            raise BuildError("video package report does not declare status=packaged")
        if report["packageReports"]["video"].get("runtimeVerification") != "not-run":
            raise BuildError("video package report has unexpected runtimeVerification")
        report.update(
            status="packaged",
            runtimeVerification="not-run",
            finalApp=str(final_app),
            protectedInputsUnchanged=True,
        )
        _write_report_exclusive(report_path, report)
        return report, report_path
    except Cancelled as error:
        report.update(status="cancelled", error=str(error))
        try:
            _write_report_exclusive(report_path, report)
        except BuildError as report_error:
            raise Cancelled(f"{error}; report failure: {report_error}") from report_error
        raise
    except (BuildError, OSError, shutil.Error, UnicodeError) as caught:
        error = caught if isinstance(caught, BuildError) else BuildError(
            f"packaging orchestration I/O failure: {caught}"
        )
        report.update(status="failed", error=str(error))
        retained = final_app if final_app.is_dir() and not final_app.is_symlink() else None
        if retained is not None:
            report["retainedPublishedApp"] = str(retained)
        try:
            _write_report_exclusive(report_path, report)
        except BuildError as report_error:
            suffix = f"; packaged App retained at {retained}" if retained is not None else ""
            raise BuildError(f"{error}; report failure: {report_error}{suffix}") from report_error
        raise error


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="absolute path to a schemaVersion 1 local JSON config")
    parser.add_argument("--run-root", required=True, help="absolute path that must not already exist")
    parser.add_argument("--timeout-per-stage", type=float, default=3600.0)
    args = parser.parse_args(argv)
    if not (args.timeout_per_stage > 0 and args.timeout_per_stage <= 24 * 60 * 60):
        parser.error("--timeout-per-stage must be greater than 0 and no more than 86400 seconds")
    return args


def main(argv: list[str] | None = None) -> int:
    def request_cancellation(signum: int, _frame: Any) -> None:
        raise Cancelled(f"received cancellation signal {signum}")

    signal.signal(signal.SIGTERM, request_cancellation)
    try:
        args = parse_arguments(sys.argv[1:] if argv is None else argv)
        config_path = _absolute(args.config, "--config")
        run_root = _absolute(args.run_root, "--run-root")
        preflight = _preflight(config_path, run_root)
        report, report_path = _execute(preflight, config_path, run_root, args.timeout_per_stage)
    except Cancelled as error:
        # Cleanup has completed. Keep repeated cancellation from replacing the
        # promised 130 status during Python's short interpreter-shutdown window.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        _safe_message(sys.stderr, {"status": "cancelled", "error": str(error), "runtimeVerification": "not-run"})
        return 130
    except (BuildError, OSError, shutil.Error, UnicodeError) as error:
        _safe_message(sys.stderr, {"status": "failed", "error": str(error), "runtimeVerification": "not-run"})
        return 2
    summary = {
        "status": report["status"],
        "runtimeVerification": report["runtimeVerification"],
        "finalApp": report["finalApp"],
        "report": str(report_path),
    }
    if _safe_message(sys.stdout, summary):
        return 0
    _safe_message(sys.stderr, {
        "status": "failed",
        "error": "stdout summary write failed after the on-disk packaged report was written",
        "finalApp": report["finalApp"],
        "onDiskReport": str(report_path),
        "onDiskReportStatus": "written",
        "runtimeVerification": "not-run",
    })
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
