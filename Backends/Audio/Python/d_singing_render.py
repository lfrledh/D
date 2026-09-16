"""Safe one-shot SING-RENDER1/spec1 renderer and command-line entry point."""

from __future__ import annotations

import sys

# A direct CLI launch must protect local provider/helper sources even when its
# caller forgot -B.  Library imports keep the caller's bytecode policy intact.
if __name__ == "__main__":
    sys.dont_write_bytecode = True

from contextlib import contextmanager
import copy
from contextvars import ContextVar
from dataclasses import dataclass
import gc
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import shutil
import signal
import stat
import struct
import time
from typing import Any, Callable, Iterator, Mapping, Sequence
import uuid

from d_audio_contract import (
    ContractError,
    checked_absolute_path,
    decode_strict_json,
    ensure_no_symlink_components,
    json_bytes,
    paths_overlap,
    publish_exclusive,
)
from d_singing_prepare import prepare_singing_plan
from d_singing_timing import build_duration_groups
from d_singing_qixuan import (
    ACOUSTIC_DEPTH,
    ACOUSTIC_STEPS,
    CONTEXT_TICKS,
    HEAD_FRAMES,
    HOP_SIZE,
    PITCH_STEPS,
    PROJECTION_BLOCK_FRAMES,
    PROJECTION_HISTORY,
    PROJECTION_MAXIMUM_RELATIVE_RESIDUAL,
    PROJECTION_MAX_ITERATIONS,
    QixuanEngine,
    QixuanRuntimeError,
    RenderCancelled,
    SAMPLE_RATE,
    TAIL_FRAMES,
    VARIANCE_STEPS,
    VocoderOutput,
)


SCHEMA_VERSION = 1
CPU_PROFILE_ID = "qixuan-2.7.0-bigvgan-44k-approx-v1"
CPU_PROFILE_SHA256 = "15489802b768fdd5c447325d5483b293601e63db54f46e84eb1c7b84df010a39"
MPS_PROFILE_ID = "qixuan-2.7.0-bigvgan-44k-approx-mps-fp32-v1"
MPS_PROFILE_SHA256 = "1d7b3fcc0988e4f76c4fe0b8fd7adf62fe943d947482c0878b51e38dfe725705"
# Compatibility aliases retained for existing CPU callers and fixtures.
PROFILE_ID = CPU_PROFILE_ID
PROFILE_SHA256 = CPU_PROFILE_SHA256
SOURCE_MANIFEST_SHA256 = "e3f9f9eb2a3cad99b5f75501cbc8b5fd6504257d0c26a69c2f1c817d2c7d0000"
VOCODER_REVISION = "95a9d1dcb12906c03edd938d77b9333d6ded7dfb"
MAX_REQUEST_BYTES = 2 * 1024 * 1024
MAX_SMALL_CONFIG_BYTES = 2 * 1024 * 1024
PURPOSES = {"internalDevelopment", "personalCreation", "commercialCreation"}
STAGE_NAMES = ("validation", "duration", "pitch", "variance", "acoustic", "vocoder", "publish")
CPU_PRECISION = "Qixuan original ONNX CPU; BigVGAN FP32 CPU"
MPS_PRECISION = "Qixuan original ONNX CPU; BigVGAN FP32 MPS"
PRECISION = CPU_PRECISION
SEED_CONTROL = "unsupported"
MAX_RUNTIME_VERSION_LENGTH = 128

_PROFILE_DESCRIPTIONS = {
    CPU_PROFILE_ID: {
        "profileSHA256": CPU_PROFILE_SHA256,
        "vocoderDevice": "cpu",
        "precision": CPU_PRECISION,
        "resultSchemaVersion": 1,
    },
    MPS_PROFILE_ID: {
        "profileSHA256": MPS_PROFILE_SHA256,
        "vocoderDevice": "mps",
        "precision": MPS_PRECISION,
        "resultSchemaVersion": 2,
    },
}

_REQUEST_KEYS = {
    "schemaVersion", "runID", "profileID", "phrase", "pronunciations",
    "vowelIndices", "qualification",
}
_QUALIFICATION_KEYS = {
    "confirmedApplicable", "purpose", "bankArchiveSHA256", "bankTermsSHA256",
    "vocoderRevision", "vocoderLicenseSHA256",
}
_PROFILE_KEYS = {
    "schemaVersion", "profileID", "bankArchiveSHA256", "bankTermsSHA256", "bankFiles",
    "vocoderRevision", "vocoderFiles", "vocoderLicenseSHA256", "sampleRate", "hopSize",
    "headFrames", "tailFrames", "pitchSteps", "varianceSteps", "acousticSteps",
    "acousticDepth", "contextTicks", "projection",
}
_PROJECTION_KEYS = {
    "kind", "sourceFmin", "sourceFmax", "targetFmin", "targetFmax", "nFFT",
    "melBands", "norm", "logBase", "nnlsBlockFrames", "nnlsHistory",
    "nnlsMaxIterations", "maximumRelativeResidual",
}
_FILE_ENTRY_KEYS = {"path", "byteCount", "sha256"}


class RenderInputError(ContractError):
    def __init__(self, message: str) -> None:
        super().__init__(message, "invalidRequest")


class RenderRuntimeError(ContractError):
    def __init__(self, message: str) -> None:
        super().__init__(message, "runtime")


def _profile_description(profile_id: Any) -> dict[str, Any]:
    if type(profile_id) is not str or profile_id not in _PROFILE_DESCRIPTIONS:
        raise RenderInputError("profileID is not one of the two fixed singing profiles")
    return _PROFILE_DESCRIPTIONS[profile_id]


def _validated_runtime_version(value: Any, label: str) -> str:
    if type(value) is not str or not value or len(value) > MAX_RUNTIME_VERSION_LENGTH:
        raise RenderRuntimeError(
            f"{label} version must be nonempty text no longer than "
            f"{MAX_RUNTIME_VERSION_LENGTH} characters"
        )
    return value


def _validated_mps_devices(value: Any) -> dict[str, dict[str, str]]:
    if type(value) is not dict or set(value) != {"onnx", "vocoder"}:
        raise RenderRuntimeError("MPS execution.devices must contain exactly onnx and vocoder")
    onnx = value["onnx"]
    vocoder = value["vocoder"]
    onnx_keys = {
        "requested", "actual", "provider", "runtime", "version", "precision", "fallback",
    }
    vocoder_keys = {
        "requested", "actual", "runtime", "version", "precision", "fallback",
        "parameterDevice", "bufferDevice", "inputDevice", "outputDevice",
    }
    if type(onnx) is not dict or set(onnx) != onnx_keys:
        raise RenderRuntimeError("MPS execution.devices.onnx has the wrong exact keys")
    if type(vocoder) is not dict or set(vocoder) != vocoder_keys:
        raise RenderRuntimeError("MPS execution.devices.vocoder has the wrong exact keys")
    expected_onnx = {
        "requested": "cpu",
        "actual": "cpu",
        "provider": "CPUExecutionProvider",
        "runtime": "onnxruntime",
        "precision": "FP32-original",
        "fallback": "forbidden",
    }
    expected_vocoder = {
        "requested": "mps",
        "actual": "mps",
        "runtime": "torch",
        "precision": "FP32",
        "fallback": "forbidden",
        "parameterDevice": "mps",
        "bufferDevice": "mps",
        "inputDevice": "mps",
        "outputDevice": "mps",
    }
    for key, expected in expected_onnx.items():
        if onnx[key] != expected:
            raise RenderRuntimeError(f"MPS ONNX device observation mismatch for {key}")
    for key, expected in expected_vocoder.items():
        if vocoder[key] != expected:
            raise RenderRuntimeError(f"MPS vocoder device observation mismatch for {key}")
    _validated_runtime_version(onnx["version"], "ONNX runtime")
    _validated_runtime_version(vocoder["version"], "torch runtime")
    return {"onnx": dict(onnx), "vocoder": dict(vocoder)}


@dataclass(frozen=True, slots=True)
class FileSeal:
    path: Path
    label: str
    byte_count: int
    sha256: str
    identity: tuple[int, int, int, int, int]


@dataclass(frozen=True, slots=True)
class MaterialBundle:
    profile: dict[str, Any]
    seals: tuple[FileSeal, ...]

    def verify(self) -> None:
        for seal in self.seals:
            _verify_seal(seal)


@dataclass(frozen=True, slots=True)
class RuntimeOwner:
    path: Path
    identity: tuple[int, int]


_ACTIVE_SEALS: ContextVar[list[FileSeal] | None] = ContextVar("singing_render_active_seals", default=None)
_ACTIVE_REQUEST: ContextVar[dict[str, Any] | None] = ContextVar("singing_render_active_request", default=None)


def _exact_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if type(value) is not dict:
        raise RenderInputError(f"{label} must be an object")
    missing = keys - value.keys()
    unknown = value.keys() - keys
    if missing:
        raise RenderInputError(f"{label} is missing keys: {', '.join(sorted(missing))}")
    if unknown:
        raise RenderInputError(f"{label} has unknown keys: {', '.join(sorted(unknown))}")
    return value


def _exact_int(value: Any, expected: int, label: str) -> None:
    if type(value) is not int or value != expected:
        raise RenderInputError(f"{label} must be integer {expected}")


def _sha256_text(value: Any, label: str) -> str:
    if type(value) is not str or len(value) != 64 or any(ch not in "0123456789abcdef" for ch in value):
        raise RenderInputError(f"{label} must be a lowercase SHA-256 string")
    return value


def _canonical_uuid(value: Any, label: str) -> str:
    if type(value) is not str:
        raise RenderInputError(f"{label} must be a canonical lowercase UUID string")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as exc:
        raise RenderInputError(f"{label} must be a canonical lowercase UUID string") from exc
    if str(parsed) != value:
        raise RenderInputError(f"{label} must be a canonical lowercase UUID string")
    return value


def _identity(info: os.stat_result) -> tuple[int, int, int, int, int]:
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def _ensure_named_regular_identity(
    path: Path, identity: tuple[int, int, int, int, int], label: str
) -> None:
    try:
        ensure_no_symlink_components(path, label=label)
        current = os.lstat(path)
    except (ContractError, OSError) as exc:
        raise RenderRuntimeError(f"cannot rebind {label} after read: {exc}") from exc
    if not stat.S_ISREG(current.st_mode) or _identity(current) != identity:
        raise RenderRuntimeError(f"{label} named path changed after read")


def _read_and_seal(
    path: Path,
    *,
    label: str,
    expected_size: int | None = None,
    expected_sha256: str | None = None,
    max_bytes: int | None = None,
    retain: bool,
) -> tuple[bytes | None, FileSeal]:
    try:
        ensure_no_symlink_components(path, label=label)
        info = os.lstat(path)
    except (ContractError, OSError) as exc:
        raise RenderInputError(str(exc)) from exc
    if not stat.S_ISREG(info.st_mode):
        raise RenderInputError(f"{label} must be a regular file")
    if expected_size is not None and info.st_size != expected_size:
        raise RenderInputError(f"{label} size mismatch")
    if max_bytes is not None and info.st_size > max_bytes:
        raise RenderInputError(f"{label} exceeds {max_bytes} bytes")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor: int | None = None
    primary: BaseException | None = None
    traceback = None
    seal: FileSeal | None = None
    retained: bytes | None = None
    try:
        descriptor = os.open(path, flags)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise RenderInputError(f"{label} must be a regular file")
        if _identity(before) != _identity(info):
            raise RenderRuntimeError(f"{label} named path changed before read")
        digest = hashlib.sha256()
        chunks: list[bytes] | None = [] if retain else None
        total = 0
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            total += len(block)
            if max_bytes is not None and total > max_bytes:
                raise RenderInputError(f"{label} exceeds {max_bytes} bytes")
            digest.update(block)
            if chunks is not None:
                chunks.append(block)
        after = os.fstat(descriptor)
        identity = _identity(before)
        if identity != _identity(after) or total != before.st_size:
            raise RenderInputError(f"{label} changed while being verified")
        actual_digest = digest.hexdigest()
        seal = FileSeal(path, label, total, actual_digest, identity)
        active_seals = _ACTIVE_SEALS.get()
        if active_seals is not None:
            active_seals.append(seal)
        retained = b"".join(chunks) if chunks is not None else None
    except BaseException as exc:
        primary = exc
        traceback = exc.__traceback__
    close_error: OSError | None = None
    if descriptor is not None:
        try:
            os.close(descriptor)
        except OSError as exc:
            close_error = exc
    if primary is not None:
        if close_error is not None and getattr(primary, "add_note", None) is not None:
            primary.add_note(f"secondary {label} close error: {close_error}")
        if isinstance(primary, (RenderInputError, RenderRuntimeError)):
            raise primary.with_traceback(traceback)
        if isinstance(primary, OSError):
            raise RenderInputError(f"cannot verify {label}: {primary}") from primary
        raise primary.with_traceback(traceback)
    if close_error is not None:
        raise RenderRuntimeError(f"cannot close verified {label}: {close_error}") from close_error
    if seal is None:
        raise RenderRuntimeError(f"{label} verification produced no stable seal")
    _ensure_named_regular_identity(path, seal.identity, label)
    if expected_sha256 is not None and seal.sha256 != expected_sha256:
        raise RenderInputError(f"{label} SHA-256 mismatch")
    return retained, seal


def _verify_seal(seal: FileSeal) -> None:
    descriptor: int | None = None
    try:
        ensure_no_symlink_components(seal.path, label=seal.label)
        info = os.lstat(seal.path)
        if not stat.S_ISREG(info.st_mode) or _identity(info) != seal.identity:
            raise RenderRuntimeError(f"protected {seal.label} identity changed")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(seal.path, flags)
        before = os.fstat(descriptor)
        if _identity(before) != seal.identity:
            raise RenderRuntimeError(f"protected {seal.label} named path changed before read")
        digest = hashlib.sha256()
        total = 0
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            total += len(block)
            digest.update(block)
        after = os.fstat(descriptor)
        if _identity(before) != seal.identity or _identity(after) != seal.identity:
            raise RenderRuntimeError(f"protected {seal.label} metadata changed")
        if total != seal.byte_count or digest.hexdigest() != seal.sha256:
            raise RenderRuntimeError(f"protected {seal.label} content changed")
    except RenderRuntimeError:
        raise
    except (ContractError, OSError) as exc:
        raise RenderRuntimeError(f"cannot reverify protected {seal.label}: {exc}") from exc
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError as exc:
                raise RenderRuntimeError(f"cannot close protected {seal.label}: {exc}") from exc
    _ensure_named_regular_identity(seal.path, seal.identity, f"protected {seal.label}")


def _relative_file(value: Any, label: str) -> PurePosixPath:
    if type(value) is not str or not value:
        raise RenderInputError(f"{label} path must be nonempty relative text")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "." in path.parts or str(path) != value:
        raise RenderInputError(f"{label} path must be normalized and relative")
    return path


def _parse_file_entries(value: Any, label: str) -> tuple[tuple[PurePosixPath, int, str], ...]:
    if type(value) is not list or not value:
        raise RenderInputError(f"{label} must be a nonempty array")
    result: list[tuple[PurePosixPath, int, str]] = []
    seen: set[str] = set()
    for index, raw in enumerate(value):
        entry = _exact_object(raw, _FILE_ENTRY_KEYS, f"{label}[{index}]")
        relative = _relative_file(entry["path"], f"{label}[{index}]")
        if str(relative) in seen:
            raise RenderInputError(f"{label} contains duplicate paths")
        seen.add(str(relative))
        size = entry["byteCount"]
        if type(size) is not int or size < 0:
            raise RenderInputError(f"{label}[{index}].byteCount must be a nonnegative integer")
        digest = _sha256_text(entry["sha256"], f"{label}[{index}].sha256")
        result.append((relative, size, digest))
    return tuple(result)


def _load_request(raw: bytes) -> dict[str, Any]:
    try:
        request = decode_strict_json(raw, label="singing render request")
    except ContractError as exc:
        raise RenderInputError(str(exc)) from exc
    _exact_object(request, _REQUEST_KEYS, "request")
    _exact_int(request["schemaVersion"], SCHEMA_VERSION, "request.schemaVersion")
    _canonical_uuid(request["runID"], "request.runID")
    _profile_description(request["profileID"])
    qualification = _exact_object(request["qualification"], _QUALIFICATION_KEYS, "qualification")
    if qualification["confirmedApplicable"] is not True:
        raise RenderInputError("qualification.confirmedApplicable must be true")
    if type(qualification["purpose"]) is not str or qualification["purpose"] not in PURPOSES:
        raise RenderInputError("qualification.purpose is unsupported")
    for key in ("bankArchiveSHA256", "bankTermsSHA256", "vocoderLicenseSHA256"):
        _sha256_text(qualification[key], f"qualification.{key}")
    if type(qualification["vocoderRevision"]) is not str:
        raise RenderInputError("qualification.vocoderRevision must be text")
    if type(request["phrase"]) is not dict or type(request["pronunciations"]) is not dict:
        raise RenderInputError("request phrase and pronunciations must be objects")
    if type(request["vowelIndices"]) is not list:
        raise RenderInputError("request.vowelIndices must be an array")
    return request


def _load_profile(raw: bytes, *, expected_profile_id: str | None = None) -> dict[str, Any]:
    try:
        profile = decode_strict_json(raw, label="singing render profile")
    except ContractError as exc:
        raise RenderInputError(str(exc)) from exc
    _exact_object(profile, _PROFILE_KEYS, "profile")
    _exact_int(profile["schemaVersion"], 1, "profile.schemaVersion")
    _profile_description(profile["profileID"])
    if expected_profile_id is not None and profile["profileID"] != expected_profile_id:
        raise RenderInputError("profile identity does not match the requested profile")
    frozen_integers = {
        "sampleRate": SAMPLE_RATE, "hopSize": HOP_SIZE, "headFrames": HEAD_FRAMES,
        "tailFrames": TAIL_FRAMES, "pitchSteps": PITCH_STEPS,
        "varianceSteps": VARIANCE_STEPS, "acousticSteps": ACOUSTIC_STEPS,
        "contextTicks": CONTEXT_TICKS,
    }
    for key, expected in frozen_integers.items():
        _exact_int(profile[key], expected, f"profile.{key}")
    if type(profile["acousticDepth"]) not in (int, float) or isinstance(profile["acousticDepth"], bool):
        raise RenderInputError("profile.acousticDepth must be numeric")
    if float(profile["acousticDepth"]) != ACOUSTIC_DEPTH:
        raise RenderInputError("profile.acousticDepth mismatch")
    if profile["vocoderRevision"] != VOCODER_REVISION:
        raise RenderInputError("profile vocoder revision mismatch")
    for key in ("bankArchiveSHA256", "bankTermsSHA256", "vocoderLicenseSHA256"):
        _sha256_text(profile[key], f"profile.{key}")
    projection = _exact_object(profile["projection"], _PROJECTION_KEYS, "profile.projection")
    expected_projection = {
        "kind": "approximate-nonnegative-amplitude-reprojection",
        "sourceFmin": 40, "sourceFmax": 16000, "targetFmin": 0, "targetFmax": 22050,
        "nFFT": 2048, "melBands": 128, "norm": "slaney", "logBase": "e",
        "nnlsBlockFrames": PROJECTION_BLOCK_FRAMES,
        "nnlsHistory": PROJECTION_HISTORY,
        "nnlsMaxIterations": PROJECTION_MAX_ITERATIONS,
        "maximumRelativeResidual": PROJECTION_MAXIMUM_RELATIVE_RESIDUAL,
    }
    if projection != expected_projection:
        raise RenderInputError("profile projection does not match the frozen contract")
    _parse_file_entries(profile["bankFiles"], "profile.bankFiles")
    _parse_file_entries(profile["vocoderFiles"], "profile.vocoderFiles")
    return profile


def _validate_qualification(request: dict[str, Any], profile: dict[str, Any]) -> None:
    qualification = request["qualification"]
    expected = {
        "bankArchiveSHA256": profile["bankArchiveSHA256"],
        "bankTermsSHA256": profile["bankTermsSHA256"],
        "vocoderRevision": profile["vocoderRevision"],
        "vocoderLicenseSHA256": profile["vocoderLicenseSHA256"],
    }
    for key, value in expected.items():
        if qualification[key] != value:
            raise RenderInputError(f"qualification.{key} does not match the fixed material")


def _checked_directory(path: Path, label: str) -> None:
    try:
        ensure_no_symlink_components(path, label=label)
        info = os.lstat(path)
    except (ContractError, OSError) as exc:
        raise RenderInputError(str(exc)) from exc
    if not stat.S_ISDIR(info.st_mode):
        raise RenderInputError(f"{label} must be a directory")


def _validate_paths(
    request_path: str,
    bank_directory: str,
    vocoder_directory: str,
    vendor_directory: str,
    profile_path: str,
    output_directory: str,
) -> tuple[Path, Path, Path, Path, Path, Path]:
    raw = (
        (request_path, "request"), (bank_directory, "bank directory"),
        (vocoder_directory, "vocoder directory"), (vendor_directory, "vendor directory"),
        (profile_path, "profile"), (output_directory, "output directory"),
    )
    try:
        paths = tuple(checked_absolute_path(value, label=label) for value, label in raw)
    except ContractError as exc:
        raise RenderInputError(str(exc)) from exc
    request, bank, vocoder, vendor, profile, output = paths
    for path, label in ((request, "request"), (profile, "profile")):
        try:
            ensure_no_symlink_components(path, label=label)
            info = os.lstat(path)
        except (ContractError, OSError) as exc:
            raise RenderInputError(str(exc)) from exc
        if not stat.S_ISREG(info.st_mode):
            raise RenderInputError(f"{label} must be a regular file")
    for path, label in ((bank, "bank directory"), (vocoder, "vocoder directory"), (vendor, "vendor directory")):
        _checked_directory(path, label)
    if not output.name:
        raise RenderInputError("output directory must name a new directory")
    try:
        ensure_no_symlink_components(output, label="output directory", allow_missing_leaf=True)
        ensure_no_symlink_components(output.parent, label="output parent")
        parent_info = os.lstat(output.parent)
    except (ContractError, OSError) as exc:
        raise RenderInputError(str(exc)) from exc
    if not stat.S_ISDIR(parent_info.st_mode):
        raise RenderInputError("output parent must be a directory")
    if os.path.lexists(output):
        raise RenderInputError("output directory must not already exist")
    for other, label in (
        (request, "request"), (bank, "bank directory"), (vocoder, "vocoder directory"),
        (vendor, "vendor directory"), (profile, "profile"),
    ):
        if paths_overlap(output, other):
            raise RenderInputError(f"output directory must be disjoint from {label}")
    return request, bank, vocoder, vendor, profile, output


def _load_source_manifest(raw: bytes) -> dict[str, Any]:
    try:
        manifest = decode_strict_json(raw, label="BigVGAN source manifest")
    except ContractError as exc:
        raise RenderInputError(str(exc)) from exc
    _exact_object(manifest, {"schemaVersion", "modelRevision", "sourceFiles"}, "source manifest")
    _exact_int(manifest["schemaVersion"], 1, "source manifest.schemaVersion")
    if manifest["modelRevision"] != VOCODER_REVISION:
        raise RenderInputError("source manifest revision mismatch")
    _parse_file_entries(manifest["sourceFiles"], "source manifest.sourceFiles")
    return manifest


def _unique_inventory_pairs(values: list[tuple[str, Any]], label: str) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in values:
        if key in result:
            raise ValueError(f"duplicate key {key!r} in {label}")
        result[key] = value
    return result


def _decode_inventory(raw: bytes, label: str) -> dict[str, int]:
    try:
        value = json.loads(
            raw.decode("utf-8-sig", errors="strict"),
            object_pairs_hook=lambda pairs: _unique_inventory_pairs(pairs, label),
            parse_constant=lambda token: (_ for _ in ()).throw(
                ValueError(f"non-finite number {token}")
            ),
        )
    except (UnicodeError, ValueError, json.JSONDecodeError, RecursionError) as exc:
        raise RenderInputError(f"invalid {label}: {exc}") from exc
    if type(value) is not dict or not value:
        raise RenderInputError(f"{label} must be a nonempty object")
    result: dict[str, int] = {}
    for key, item in value.items():
        if type(key) is not str or not key or type(item) is not int or item < 0:
            raise RenderInputError(
                f"{label} must map nonempty strings to nonnegative integer IDs"
            )
        result[key] = item
    return result


def _validate_fixed_inventories(
    request: dict[str, Any], profile: dict[str, Any], bank_directory: Path
) -> None:
    entries = {
        str(path): (size, digest)
        for path, size, digest in _parse_file_entries(profile["bankFiles"], "profile.bankFiles")
    }
    models = (
        ("", "0101_qixuan_muon1_acoustic"),
        ("dsdur", "0102_qixuan_newdict_dur"),
        ("dspitch", "0102_qixuan_muon1_pitch"),
        ("dsvariance", "0102_qixuan_muon1_multivar"),
    )
    used_phonemes = tuple(
        phoneme
        for unit in request["pronunciations"]["units"]
        for phoneme in unit["phonemes"]
    )
    for folder, stem in models:
        prefix = f"{folder}/" if folder else ""
        mappings: dict[str, dict[str, int]] = {}
        for kind in ("phonemes", "languages"):
            relative = f"{prefix}{stem}.{kind}.json"
            expected = entries.get(relative)
            if expected is None:
                raise RenderInputError(f"fixed profile has no {relative} identity")
            raw, _seal = _read_and_seal(
                bank_directory.joinpath(*PurePosixPath(relative).parts),
                label=f"fixed {stem} {kind}", expected_size=expected[0],
                expected_sha256=expected[1], max_bytes=MAX_SMALL_CONFIG_BYTES, retain=True,
            )
            assert raw is not None
            mappings[kind] = _decode_inventory(raw, f"fixed {stem} {kind}")
        if "zh" not in mappings["languages"]:
            raise RenderInputError(f"fixed {stem} language inventory has no zh ID")
        unknown = sorted(set(used_phonemes) - mappings["phonemes"].keys())
        if unknown:
            raise RenderInputError(
                f"fixed {stem} phoneme inventory does not contain: {', '.join(unknown)}"
            )


def _validate_materials(
    request_seal: FileSeal,
    profile_seal: FileSeal,
    profile: dict[str, Any],
    bank_directory: Path,
    vocoder_directory: Path,
    vendor_directory: Path,
) -> MaterialBundle:
    seals: list[FileSeal] = [request_seal, profile_seal]
    manifest_path = vendor_directory / "source-manifest.json"
    manifest_raw, manifest_seal = _read_and_seal(
        manifest_path, label="BigVGAN source manifest", expected_sha256=SOURCE_MANIFEST_SHA256,
        max_bytes=MAX_SMALL_CONFIG_BYTES, retain=True,
    )
    assert manifest_raw is not None
    manifest = _load_source_manifest(manifest_raw)
    seals.append(manifest_seal)
    groups = (
        (bank_directory, _parse_file_entries(profile["bankFiles"], "profile.bankFiles"), "bank"),
        (vocoder_directory, _parse_file_entries(profile["vocoderFiles"], "profile.vocoderFiles"), "vocoder"),
        (vendor_directory / "bigvgan", _parse_file_entries(manifest["sourceFiles"], "source manifest.sourceFiles"), "vendor source"),
    )
    for root, entries, group_label in groups:
        for relative, size, digest in entries:
            path = root.joinpath(*relative.parts)
            _, seal = _read_and_seal(
                path, label=f"{group_label} {relative}", expected_size=size,
                expected_sha256=digest, retain=False,
            )
            seals.append(seal)
    active_request = _ACTIVE_REQUEST.get()
    if active_request is None:
        raise RenderRuntimeError("material validation has no bound request")
    _validate_fixed_inventories(active_request, profile, bank_directory)
    return MaterialBundle(profile=profile, seals=tuple(seals))


def _create_output_directory(path: Path) -> tuple[int, int]:
    try:
        os.mkdir(path, 0o700)
        info = os.lstat(path)
    except FileExistsError as exc:
        raise RenderInputError("output directory was created concurrently") from exc
    except OSError as exc:
        raise RenderRuntimeError(f"cannot create output directory: {exc}") from exc
    if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700:
        raise RenderRuntimeError("owned output directory does not have mode 0700")
    return info.st_dev, info.st_ino


def _ensure_owned_directory(path: Path, identity: tuple[int, int]) -> None:
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise RenderRuntimeError(f"cannot inspect owned output directory: {exc}") from exc
    if not stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) != identity:
        raise RenderRuntimeError("owned output directory identity changed")


@contextmanager
def _runtime_environment(
    output: Path, output_identity: tuple[int, int]
) -> Iterator[RuntimeOwner]:
    _ensure_owned_directory(output, output_identity)
    runtime = output / ".runtime"
    try:
        os.mkdir(runtime, 0o700)
        runtime_info = os.lstat(runtime)
        if not stat.S_ISDIR(runtime_info.st_mode):
            raise RenderRuntimeError("created runtime path is not a directory")
        owner = RuntimeOwner(runtime, (runtime_info.st_dev, runtime_info.st_ino))
        _ensure_owned_directory(output, output_identity)
        locations = {
            "TMPDIR": runtime / "tmp",
            "XDG_CACHE_HOME": runtime / "xdg-cache",
            "MPLCONFIGDIR": runtime / "matplotlib",
            "NUMBA_CACHE_DIR": runtime / "numba",
            "HF_HOME": runtime / "huggingface",
        }
        for path in locations.values():
            os.mkdir(path, 0o700)
    except OSError as exc:
        raise RenderRuntimeError(f"cannot create owned runtime directories: {exc}") from exc
    updates = {name: str(path) for name, path in locations.items()}
    updates.update({
        "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_DATASETS_OFFLINE": "1",
    })
    original = {name: os.environ.get(name) for name in updates}
    original_bytecode = sys.dont_write_bytecode
    try:
        for name, value in updates.items():
            os.environ[name] = value
        sys.dont_write_bytecode = True
        yield owner
    finally:
        sys.dont_write_bytecode = original_bytecode
        for name, value in original.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def _cleanup_runtime(owner: RuntimeOwner, output: Path, identity: tuple[int, int]) -> None:
    _ensure_owned_directory(output, identity)
    runtime = owner.path
    try:
        info = os.lstat(runtime)
    except FileNotFoundError:
        return
    except OSError as exc:
        raise RenderRuntimeError(f"cannot inspect owned runtime directory: {exc}") from exc
    if (
        not stat.S_ISDIR(info.st_mode)
        or stat.S_ISLNK(info.st_mode)
        or runtime.parent != output
        or (info.st_dev, info.st_ino) != owner.identity
    ):
        raise RenderRuntimeError("owned runtime directory identity/type changed")
    try:
        shutil.rmtree(runtime)
    except OSError as exc:
        raise RenderRuntimeError(f"cannot remove owned runtime directory: {exc}") from exc


def _emit(progress: Callable[[dict[str, str]], None], run_id: str, stage: str) -> None:
    progress({"type": "progress", "runID": run_id, "stage": stage})


def _run_stage(
    name: str,
    run_id: str,
    stages: list[dict[str, Any]],
    progress: Callable[[dict[str, str]], None],
    checkpoint: Callable[[], None],
    operation: Callable[[], Any],
) -> Any:
    _emit(progress, run_id, name)
    checkpoint()
    started = time.monotonic()
    result = operation()
    checkpoint()
    elapsed = time.monotonic() - started
    if not math.isfinite(elapsed) or elapsed < 0:
        raise RenderRuntimeError(f"invalid timing for {name}")
    stages.append({"name": name, "seconds": elapsed})
    return result


def _round_half_up_samples(duration_ticks: int) -> int:
    numerator = duration_ticks * SAMPLE_RATE
    return (numerator + 500_000) // 1_000_000


def encode_mono_float32_wave(samples: Any, frame_count: int) -> bytes:
    try:
        import numpy as np
    except Exception as exc:
        raise RenderRuntimeError(f"NumPy is unavailable while encoding WAV: {exc}") from exc
    values = np.asarray(samples)
    if values.shape != (frame_count,) or values.dtype != np.float32:
        raise RenderRuntimeError("output PCM must be a float32 vector matching frameCount")
    if frame_count <= 0 or not bool(np.isfinite(values).all()) or not bool(np.any(values != 0)):
        raise RenderRuntimeError("output PCM must be finite, nonempty, and nonzero")
    payload = values.astype("<f4", copy=False).tobytes()
    fmt = struct.pack("<HHIIHH", 3, 1, SAMPLE_RATE, SAMPLE_RATE * 4, 4, 32)
    riff_size = 4 + 8 + len(fmt) + 8 + len(payload)
    if riff_size > 0xFFFFFFFF:
        raise RenderRuntimeError("output WAV exceeds RIFF size")
    return b"RIFF" + struct.pack("<I", riff_size) + b"WAVEfmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(payload)) + payload


def validate_mono_float32_wave(raw: bytes, expected_frames: int) -> str:
    if len(raw) < 44 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise RenderRuntimeError("published WAV is not RIFF/WAVE")
    if struct.unpack_from("<I", raw, 4)[0] + 8 != len(raw):
        raise RenderRuntimeError("published WAV RIFF length mismatch")
    offset = 12
    format_chunk: bytes | None = None
    data: bytes | None = None
    while offset < len(raw):
        if offset + 8 > len(raw):
            raise RenderRuntimeError("published WAV has a truncated chunk")
        chunk_id = raw[offset:offset + 4]
        size = struct.unpack_from("<I", raw, offset + 4)[0]
        begin, end = offset + 8, offset + 8 + size
        padded = end + (size & 1)
        if padded > len(raw):
            raise RenderRuntimeError("published WAV has a truncated chunk body")
        if chunk_id == b"fmt ":
            if format_chunk is not None:
                raise RenderRuntimeError("published WAV has duplicate fmt chunks")
            format_chunk = raw[begin:end]
        elif chunk_id == b"data":
            if data is not None:
                raise RenderRuntimeError("published WAV has duplicate data chunks")
            data = raw[begin:end]
        offset = padded
    if offset != len(raw) or format_chunk is None or data is None or len(format_chunk) != 16:
        raise RenderRuntimeError("published WAV structure is invalid")
    tag, channels, rate, byte_rate, align, bits = struct.unpack("<HHIIHH", format_chunk)
    if (tag, channels, rate, byte_rate, align, bits) != (3, 1, SAMPLE_RATE, SAMPLE_RATE * 4, 4, 32):
        raise RenderRuntimeError("published WAV format is not mono 44.1 kHz float32")
    if len(data) != expected_frames * 4:
        raise RenderRuntimeError("published WAV frame count mismatch")
    try:
        import numpy as np
        samples = np.frombuffer(data, dtype="<f4")
    except Exception as exc:
        raise RenderRuntimeError(f"cannot inspect published WAV samples: {exc}") from exc
    if not bool(np.isfinite(samples).all()) or not bool(np.any(samples != 0)):
        raise RenderRuntimeError("published WAV samples must be finite and nonzero")
    return hashlib.sha256(raw).hexdigest()


def _prepare_delivery(vocoder: VocoderOutput, duration_ticks: int) -> tuple[Any, int, int]:
    try:
        import numpy as np
    except Exception as exc:
        raise RenderRuntimeError(f"NumPy is unavailable while trimming: {exc}") from exc
    samples = np.asarray(vocoder.samples)
    if samples.dtype != np.float32 or samples.ndim != 1:
        raise RenderRuntimeError("vocoder output must be a one-dimensional float32 array")
    if len(samples) != vocoder.native_frame_count or not bool(np.isfinite(samples).all()):
        raise RenderRuntimeError("vocoder native frame count/content mismatch")
    head = HEAD_FRAMES * HOP_SIZE
    output_frames = _round_half_up_samples(duration_ticks)
    if output_frames <= 0 or head + output_frames > len(samples):
        raise RenderRuntimeError("vocoder did not produce enough samples for the exact source duration")
    delivered = samples[head:head + output_frames].copy()
    saturated = int(np.count_nonzero(np.abs(delivered) >= 1.0))
    return delivered, output_frames, saturated


def _build_result(
    request: dict[str, Any], request_digest: str, profile: dict[str, Any], wav_digest: str,
    vocoder: VocoderOutput, output_frames: int, saturated: int,
    stages: list[dict[str, Any]],
) -> dict[str, Any]:
    description = _profile_description(request["profileID"])
    if profile["profileID"] != request["profileID"]:
        raise RenderRuntimeError("result request/profile identity mismatch")
    phrase = request["phrase"]
    vocoder_files = _parse_file_entries(profile["vocoderFiles"], "profile.vocoderFiles")
    weight_digest = next((digest for path, _size, digest in vocoder_files if str(path) == "bigvgan_generator.pt"), None)
    if weight_digest is None:
        raise RenderRuntimeError("fixed profile has no BigVGAN weight identity")
    result = {
        "schemaVersion": description["resultSchemaVersion"],
        "runID": request["runID"],
        "profileID": request["profileID"],
        "status": "rendered",
        "source": {
            "phraseID": phrase["id"], "phraseRevision": phrase["revision"],
            "requestSHA256": request_digest, "durationTicks": phrase["durationTicks"],
        },
        "model": {
            "bankArchiveSHA256": profile["bankArchiveSHA256"],
            "vocoderRevision": profile["vocoderRevision"],
            "vocoderSHA256": weight_digest,
            "bankTermsSHA256": profile["bankTermsSHA256"],
            "vocoderLicenseSHA256": profile["vocoderLicenseSHA256"],
        },
        "audio": {
            "path": "output.wav", "encoding": "float32LE-WAV", "sampleRate": SAMPLE_RATE,
            "channels": 1, "frameCount": output_frames, "sha256": wav_digest,
        },
        "execution": {
            "precision": description["precision"], "seedControl": SEED_CONTROL,
            "nativeFrameCount": vocoder.native_frame_count,
            "trimHeadSamples": HEAD_FRAMES * HOP_SIZE,
            "outputFrameCount": output_frames,
            "projectionRelativeResidual": vocoder.projection_relative_residual,
            "saturatedSamples": saturated,
            "stages": stages,
        },
    }
    if description["vocoderDevice"] == "mps":
        result["model"]["profileSHA256"] = description["profileSHA256"]
        result["model"]["vendorManifestSHA256"] = SOURCE_MANIFEST_SHA256
        result["execution"]["devices"] = _validated_mps_devices(vocoder.devices)
    return result


def _validate_result_bytes(raw: bytes, expected: dict[str, Any]) -> None:
    try:
        decoded = decode_strict_json(raw, label="singing render result")
    except ContractError as exc:
        raise RenderRuntimeError(str(exc)) from exc
    if decoded != expected:
        raise RenderRuntimeError("published result does not match the committed result")


def _readback_owned_target(
    output: Path,
    output_identity: tuple[int, int],
    filename: str,
    *,
    maximum_bytes: int,
) -> bytes:
    """Sync and read an ordinary final target without following replacements."""
    _ensure_owned_directory(output, output_identity)
    target = output / filename
    descriptor: int | None = None
    primary_error: BaseException | None = None
    primary_traceback = None
    result: bytes | None = None
    verified_identity: tuple[int, int, int, int, int] | None = None
    try:
        entry = os.lstat(target)
        if not stat.S_ISREG(entry.st_mode):
            raise RenderRuntimeError(f"published {filename} is not an ordinary file")
        if entry.st_size > maximum_bytes:
            raise RenderRuntimeError(f"published {filename} exceeds its byte bound")
        descriptor = os.open(
            target,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or (before.st_dev, before.st_ino) != (entry.st_dev, entry.st_ino):
            raise RenderRuntimeError(f"published {filename} identity changed before readback")
        os.fsync(descriptor)
        chunks: list[bytes] = []
        total = 0
        while True:
            block = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - total))
            if not block:
                break
            total += len(block)
            if total > maximum_bytes:
                raise RenderRuntimeError(f"published {filename} exceeds its byte bound")
            chunks.append(block)
        after = os.fstat(descriptor)
        if _identity(before) != _identity(after) or total != before.st_size:
            raise RenderRuntimeError(f"published {filename} changed during readback")
        verified_identity = _identity(after)
        result = b"".join(chunks)
    except BaseException as exc:
        primary_error = exc
        primary_traceback = exc.__traceback__
    close_error: BaseException | None = None
    if descriptor is not None:
        try:
            os.close(descriptor)
        except OSError as exc:
            close_error = RenderRuntimeError(f"cannot close published {filename}: {exc}")
    path_error: BaseException | None = None
    if verified_identity is not None:
        try:
            _ensure_owned_directory(output, output_identity)
            _ensure_named_regular_identity(target, verified_identity, f"published {filename}")
        except BaseException as exc:
            path_error = exc
    if primary_error is not None:
        if close_error is not None and getattr(primary_error, "add_note", None) is not None:
            primary_error.add_note(f"secondary final-readback close error: {close_error}")
        if path_error is not None and getattr(primary_error, "add_note", None) is not None:
            primary_error.add_note(f"secondary final named-path error: {path_error}")
        if isinstance(primary_error, RenderRuntimeError):
            raise primary_error.with_traceback(primary_traceback)
        if isinstance(primary_error, OSError):
            raise RenderRuntimeError(
                f"cannot read back published {filename}: {primary_error}"
            ) from primary_error
        raise primary_error.with_traceback(primary_traceback)
    if close_error is not None:
        raise close_error
    if path_error is not None:
        raise path_error
    if result is None:
        raise RenderRuntimeError(f"published {filename} readback produced no result")
    return result


def _verify_protected_seals(seals: Sequence[FileSeal]) -> None:
    seen: set[tuple[Path, tuple[int, int, int, int, int], str]] = set()
    for seal in seals:
        key = (seal.path, seal.identity, seal.sha256)
        if key in seen:
            continue
        seen.add(key)
        _verify_seal(seal)


def _protect_primary(seals: Sequence[FileSeal], primary: BaseException) -> None:
    if not seals:
        raise primary
    try:
        _verify_protected_seals(seals)
    except BaseException as protection:
        note = getattr(protection, "add_note", None)
        if note is not None:
            note(f"primary failure before protection check: {primary}")
        raise protection from primary
    raise primary


_ENGINE_CLASS: Any = QixuanEngine


def render(
    request_path: str,
    bank_directory: str,
    vocoder_directory: str,
    vendor_directory: str,
    profile_path: str,
    output_directory: str,
    *,
    progress: Callable[[dict[str, str]], None],
    checkpoint: Callable[[], None],
) -> dict[str, Any]:
    """Validate, execute once, and commit output.wav followed by result.json."""
    started = time.monotonic()
    protected_seals: list[FileSeal] = []
    seals_token = _ACTIVE_SEALS.set(protected_seals)
    request_token = None
    output: Path | None = None
    try:
        request_file, bank, vocoder_dir, vendor, profile_file, output = _validate_paths(
            request_path, bank_directory, vocoder_directory, vendor_directory,
            profile_path, output_directory,
        )
        request_raw, request_seal = _read_and_seal(
            request_file, label="request", max_bytes=MAX_REQUEST_BYTES, retain=True,
        )
        assert request_raw is not None
        request = _load_request(request_raw)
        description = _profile_description(request["profileID"])
        request_token = _ACTIVE_REQUEST.set(request)
        run_id = request["runID"]
        stages: list[dict[str, Any]] = []
        _emit(progress, run_id, "validation")
        checkpoint()
        profile_raw, profile_seal = _read_and_seal(
            profile_file, label="profile", expected_sha256=description["profileSHA256"],
            max_bytes=MAX_SMALL_CONFIG_BYTES, retain=True,
        )
        assert profile_raw is not None
        profile = _load_profile(profile_raw, expected_profile_id=request["profileID"])
        _validate_qualification(request, profile)
        try:
            prepared = prepare_singing_plan(request["phrase"], request["pronunciations"])
            plan = build_duration_groups(
                request["phrase"], request["pronunciations"], request["vowelIndices"],
                sample_rate=SAMPLE_RATE, hop_size=HOP_SIZE, context_ticks=CONTEXT_TICKS,
            )
        except ContractError as exc:
            raise RenderInputError(str(exc)) from exc
        original_inputs = copy.deepcopy((request["phrase"], request["pronunciations"], request["vowelIndices"]))
        if prepared["sourcePhrase"] != request["phrase"] or prepared["pronunciations"] != request["pronunciations"]:
            raise RenderInputError("preparation did not preserve the source inputs")
        bundle = _validate_materials(
            request_seal, profile_seal, profile, bank, vocoder_dir, vendor,
        )
        checkpoint()
        validation_seconds = time.monotonic() - started
        if not math.isfinite(validation_seconds) or validation_seconds < 0:
            raise RenderRuntimeError("invalid validation timing")
        stages.append({"name": "validation", "seconds": validation_seconds})

        output_identity = _create_output_directory(output)
        if description["vocoderDevice"] == "cpu":
            engine: Any = _ENGINE_CLASS(bank, vocoder_dir, vendor)
        else:
            engine = _ENGINE_CLASS(
                bank, vocoder_dir, vendor, vocoder_device=description["vocoderDevice"]
            )
        runtime_owner: RuntimeOwner | None = None

        def execute_vocoder() -> VocoderOutput:
            # The next operation imports BigVGAN source.  Rebind every source
            # identity immediately before any vendor code can execute.
            _verify_protected_seals(protected_seals)
            return engine.vocoder(acoustic, checkpoint)

        with _runtime_environment(output, output_identity) as runtime_owner:
            alignment = _run_stage(
                "duration", run_id, stages, progress, checkpoint,
                lambda: engine.duration(plan, checkpoint),
            )
            pitch = _run_stage(
                "pitch", run_id, stages, progress, checkpoint,
                lambda: engine.pitch(alignment, checkpoint),
            )
            variance = _run_stage(
                "variance", run_id, stages, progress, checkpoint,
                lambda: engine.variance(alignment, pitch, checkpoint),
            )
            acoustic = _run_stage(
                "acoustic", run_id, stages, progress, checkpoint,
                lambda: engine.acoustic(alignment, pitch, variance, checkpoint),
            )
            rendered: VocoderOutput = _run_stage(
                "vocoder", run_id, stages, progress, checkpoint,
                execute_vocoder,
            )
            if description["vocoderDevice"] == "mps":
                _validated_mps_devices(rendered.devices)
        engine = None
        gc.collect()

        _emit(progress, run_id, "publish")
        checkpoint()
        publish_started = time.monotonic()
        _ensure_owned_directory(output, output_identity)
        delivered, output_frames, saturated = _prepare_delivery(
            rendered, request["phrase"]["durationTicks"]
        )
        wav_bytes = encode_mono_float32_wave(delivered, output_frames)
        wav_digest = validate_mono_float32_wave(wav_bytes, output_frames)
        publish_exclusive(
            output, "output.wav", wav_bytes,
            validate=lambda raw: validate_mono_float32_wave(raw, output_frames),
        )
        _ensure_owned_directory(output, output_identity)
        reread_wav = _readback_owned_target(
            output, output_identity, "output.wav", maximum_bytes=len(wav_bytes)
        )
        if reread_wav != wav_bytes or validate_mono_float32_wave(reread_wav, output_frames) != wav_digest:
            raise RenderRuntimeError("published WAV digest changed on final readback")
        if (request["phrase"], request["pronunciations"], request["vowelIndices"]) != original_inputs:
            raise RenderRuntimeError("source request objects changed during rendering")
        _verify_protected_seals(protected_seals)
        if runtime_owner is not None:
            _cleanup_runtime(runtime_owner, output, output_identity)
        checkpoint()  # Last cancellation point: result.json is not yet committed.
        publish_seconds = time.monotonic() - publish_started
        if not math.isfinite(publish_seconds) or publish_seconds < 0:
            raise RenderRuntimeError("invalid publish timing")
        stages.append({"name": "publish", "seconds": publish_seconds})
        if tuple(item["name"] for item in stages) != STAGE_NAMES:
            raise RenderRuntimeError("stage record sequence mismatch")
        result = _build_result(
            request, request_seal.sha256, profile, wav_digest, rendered,
            output_frames, saturated, stages,
        )
        encoded_result = json_bytes(result)
        publish_exclusive(
            output, "result.json", encoded_result,
            validate=lambda raw: _validate_result_bytes(raw, result),
        )
        reread_result = _readback_owned_target(
            output, output_identity, "result.json", maximum_bytes=len(encoded_result)
        )
        if reread_result != encoded_result:
            raise RenderRuntimeError("published result bytes changed on final readback")
        _validate_result_bytes(reread_result, result)
        # No checkpoint after publication starts.  The commit point is reached
        # only after this final target readback and sync complete.
        _ensure_owned_directory(output, output_identity)
        return result
    except RenderInputError as exc:
        _protect_primary(protected_seals, exc)
    except RenderCancelled as exc:
        _protect_primary(protected_seals, exc)
    except BaseException as exc:
        primary = exc
        if not isinstance(exc, (RenderRuntimeError, QixuanRuntimeError, OSError, ContractError)):
            primary = RenderRuntimeError(f"unexpected render failure: {type(exc).__name__}: {exc}")
        _protect_primary(protected_seals, primary)
    finally:
        if request_token is not None:
            _ACTIVE_REQUEST.reset(request_token)
        _ACTIVE_SEALS.reset(seals_token)


def _parse_arguments(argv: Sequence[str]) -> dict[str, str]:
    allowed = {
        "--request", "--bank-directory", "--vocoder-directory", "--vendor-directory",
        "--profile", "--output-directory",
    }
    if len(argv) != 12:
        raise RenderInputError("expected exactly six option/path pairs")
    result: dict[str, str] = {}
    for index in range(0, len(argv), 2):
        option = argv[index]
        if option not in allowed or option in result:
            raise RenderInputError("expected every frozen CLI option exactly once")
        result[option] = argv[index + 1]
    if set(result) != allowed:
        raise RenderInputError("expected every frozen CLI option exactly once")
    return result


def _write_descriptor(descriptor: int, payload: bytes) -> None:
    view = memoryview(payload)
    offset = 0
    while offset < len(view):
        count = os.write(descriptor, view[offset:])
        if count <= 0:
            raise OSError("short diagnostic/notification write")
        offset += count


def _write_error(error: BaseException | str) -> None:
    message = str(error)
    if isinstance(error, BaseException):
        notes = getattr(error, "__notes__", ())
        if notes:
            message = " | ".join((message, *(str(note) for note in notes)))
    compact = " ".join(message.splitlines())[:1000]
    try:
        _write_descriptor(2, f"singing render failed: {compact}\n".encode("utf-8", errors="replace"))
    except OSError:
        pass


@contextmanager
def _signal_cancellation() -> Iterator[Callable[[], None]]:
    cancelled = False

    def handler(_number: int, _frame: Any) -> None:
        nonlocal cancelled
        cancelled = True

    previous: dict[int, Any] = {}
    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.getsignal(number)
            signal.signal(number, handler)

        def checkpoint() -> None:
            if cancelled:
                raise RenderCancelled("render cancelled")

        yield checkpoint
    finally:
        for number, old_handler in previous.items():
            signal.signal(number, old_handler)


def main(argv: Sequence[str] | None = None) -> int:
    try:
        arguments = _parse_arguments(sys.argv[1:] if argv is None else argv)
    except RenderInputError as exc:
        _write_error(exc)
        return 2

    def progress(event: dict[str, str]) -> None:
        _write_descriptor(1, json_bytes(event))

    try:
        with _signal_cancellation() as checkpoint:
            result = render(
                arguments["--request"], arguments["--bank-directory"],
                arguments["--vocoder-directory"], arguments["--vendor-directory"],
                arguments["--profile"], arguments["--output-directory"],
                progress=progress, checkpoint=checkpoint,
            )
            # Keep the signal handler installed through the final notification.
            # A signal after the commit point merely sets a now-unobserved flag.
            _write_descriptor(1, json_bytes({
                "type": "result", "runID": result["runID"], "resultPath": "result.json",
            }))
        return 0
    except RenderCancelled as exc:
        _write_error(exc)
        return 130
    except RenderInputError as exc:
        _write_error(exc)
        return 2
    except BaseException as exc:
        _write_error(exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
