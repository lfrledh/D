"""Frozen request, model, conditioning, and WAV contract for MRT2-small."""

from __future__ import annotations

from array import array
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import stat
import struct
import sys
from typing import Any, Callable, Iterable, Iterator
import uuid

from d_audio_contract import (
    ContractError,
    checked_absolute_path,
    decode_strict_json,
    ensure_no_symlink_components,
    paths_overlap,
    read_regular_file,
)


SCHEMA_VERSION = 1
PROFILE = "mrt2-small-export-v1"
MODEL_REPOSITORY = "google/magenta-realtime-2"
MODEL_REVISION = "010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc"
MODEL_LICENSE = "CC-BY-4.0; model card additional responsible use terms"
SDK_REVISION = "694a545e4ba0b88bf1150137b129582166d3e07f"
SAMPLE_RATE = 48_000
CHANNELS = 2
FRAME_RATE = 25
SAMPLES_PER_CONDITION_FRAME = 1_920
NOTES_WIDTH = 128
MAX_REQUEST_BYTES = 1 << 20
MAX_MANIFEST_BYTES = 2 << 20
MAX_JSON_DEPTH = 16
MAX_PROMPT_BYTES = 4_096
MAX_DURATION_FRAMES = 400
MAX_NOTES = 512


@dataclass(frozen=True)
class WeightEntry:
    relative_path: str
    size: int
    sha256: str

    def metadata(self) -> dict[str, Any]:
        return {"path": self.relative_path, "size": self.size, "sha256": self.sha256}


FIXED_FILES = (
    WeightEntry(
        "models/mrt2_small/mrt2_small.mlxfn",
        455_654_550,
        "1a70b0de30b3e6ad054fe6a61a7765408f01127628e6362c1abc328809a3c422",
    ),
    WeightEntry(
        "models/mrt2_small/mrt2_small_state.safetensors",
        8_676_998,
        "23f1e05a6beea306fe39970bd61193f2d3e5fbd8f08af93570bda4ca9ec33255",
    ),
    WeightEntry(
        "resources/musiccoca/mapper.tflite",
        86_166_664,
        "2f9743cc8f121a588b69c7f4d79a2a4111ce81864cbde8830054cd5e97f3d717",
    ),
    WeightEntry(
        "resources/musiccoca/pretrained_vector_quantizer.tflite",
        72_422_108,
        "7a8a19e2119ad405818eae84a331a970f1a582b3389d4bfd27814f75b455a444",
    ),
    WeightEntry(
        "resources/musiccoca/spm.model",
        517_448,
        "ff325a99b61ba5726cf6437cde6eefbb633dbaa363a684f7a97ed99b55202cca",
    ),
    WeightEntry(
        "resources/musiccoca/text_encoder.tflite",
        418_674_324,
        "e1222e3418cbe8cc2623939571bae8e9ab6f0d511404b0d83da69f4e6e11b272",
    ),
)


@dataclass(frozen=True)
class ManifestSpec:
    schema_version: int = SCHEMA_VERSION
    profile: str = PROFILE
    repository: str = MODEL_REPOSITORY
    revision: str = MODEL_REVISION
    license: str = MODEL_LICENSE
    files: tuple[WeightEntry, ...] = FIXED_FILES

    @property
    def required_weight_bytes(self) -> int:
        return sum(entry.size for entry in self.files)

    def provenance(self) -> list[dict[str, Any]]:
        return [entry.metadata() for entry in self.files]


FIXED_MANIFEST = ManifestSpec()


@dataclass(frozen=True)
class NoteEvent:
    pitch: int
    start_frame: int
    end_frame: int

    def snapshot(self) -> dict[str, int]:
        return {
            "pitch": self.pitch,
            "startFrame": self.start_frame,
            "endFrame": self.end_frame,
        }


@dataclass(frozen=True)
class NoteSequence:
    duration_frames: int
    notes: tuple[NoteEvent, ...] | None

    @property
    def notes_mode(self) -> str:
        if self.notes is None:
            return "absent"
        if not self.notes:
            return "explicitEmpty"
        return "notes"

    def snapshot(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "schemaVersion": 1,
            "frameRate": FRAME_RATE,
            "durationFrames": self.duration_frames,
        }
        if self.notes is not None:
            result["notes"] = [note.snapshot() for note in self.notes]
        return result


@dataclass(frozen=True)
class MRT2Request:
    snapshot: dict[str, Any]
    run_id: str
    prompt: str
    duration_seconds: float
    seed: int
    sequence: NoteSequence

    @property
    def frame_count(self) -> int:
        return self.sequence.duration_frames * SAMPLES_PER_CONDITION_FRAME

    def condition_metadata(self) -> dict[str, Any]:
        return {
            "sequence": self.sequence.snapshot(),
            "notesMode": self.sequence.notes_mode,
        }


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _exact_keys(
    value: dict[str, Any], required: set[str], optional: set[str], label: str
) -> None:
    missing = required - value.keys()
    unknown = value.keys() - required - optional
    if missing:
        raise ContractError(f"{label} is missing keys: {', '.join(sorted(missing))}")
    if unknown:
        raise ContractError(f"{label} has unknown keys: {', '.join(sorted(unknown))}")


def _integer(value: Any, *, label: str, low: int, high: int) -> int:
    if not _is_int(value) or not low <= value <= high:
        raise ContractError(f"{label} must be an integer in {low}...{high}")
    return value


def _json_depth(value: Any) -> int:
    maximum = 0
    stack: list[tuple[Any, int]] = [(value, 1)]
    while stack:
        current, depth = stack.pop()
        maximum = max(maximum, depth)
        if isinstance(current, dict):
            stack.extend(
                (child, depth + 1)
                for child in current.values()
                if isinstance(child, (dict, list))
            )
        elif isinstance(current, list):
            stack.extend(
                (child, depth + 1)
                for child in current
                if isinstance(child, (dict, list))
            )
    return maximum


def decode_mrt2_json(raw: bytes, *, label: str) -> dict[str, Any]:
    value = decode_strict_json(raw, label=label)
    if _json_depth(value) > MAX_JSON_DEPTH:
        raise ContractError(f"invalid {label} JSON: nesting exceeds {MAX_JSON_DEPTH} containers")
    return value


def load_mrt2_json(path: Path, *, label: str, max_bytes: int) -> dict[str, Any]:
    raw, _identity = read_regular_file(path, max_bytes=max_bytes, label=label)
    return decode_mrt2_json(raw, label=label)


def validate_request(value: dict[str, Any]) -> MRT2Request:
    _exact_keys(
        value,
        {
            "schemaVersion",
            "runID",
            "operation",
            "prompt",
            "durationSeconds",
            "seed",
            "parameters",
        },
        set(),
        "request",
    )
    if not _is_int(value["schemaVersion"]) or value["schemaVersion"] != 1:
        raise ContractError("request schemaVersion must be integer 1")
    run_id = value["runID"]
    try:
        if not isinstance(run_id, str) or str(uuid.UUID(run_id)) != run_id:
            raise ValueError
    except (ValueError, AttributeError, TypeError):
        raise ContractError("runID must be a lowercase canonical UUID") from None
    if value["operation"] != "generate":
        raise ContractError("MRT2 operation must be generate")
    prompt = value["prompt"]
    if not isinstance(prompt, str):
        raise ContractError("prompt must be Unicode text")
    try:
        prompt_bytes = prompt.encode("utf-8", errors="strict")
    except UnicodeEncodeError as exc:
        raise ContractError("prompt contains an invalid Unicode surrogate") from exc
    if not prompt.strip() or "\0" in prompt or len(prompt_bytes) > MAX_PROMPT_BYTES:
        raise ContractError("prompt must be nonblank, NUL-free, and at most 4096 UTF-8 bytes")
    duration = value["durationSeconds"]
    if isinstance(duration, bool) or not isinstance(duration, (int, float)):
        raise ContractError("durationSeconds must be a finite number")
    try:
        duration_seconds = float(duration)
    except (ValueError, OverflowError) as exc:
        raise ContractError("durationSeconds must be a finite number") from exc
    if not math.isfinite(duration_seconds) or duration_seconds <= 0:
        raise ContractError("durationSeconds must be a positive finite number")
    seed = _integer(value["seed"], label="seed", low=0, high=2**32 - 1)

    parameters = value["parameters"]
    if not isinstance(parameters, dict):
        raise ContractError("parameters must be an object")
    _exact_keys(parameters, {"kind", "sequence"}, set(), "parameters")
    if parameters["kind"] != "mrt2FixedV1":
        raise ContractError("parameters.kind must be mrt2FixedV1")
    sequence_value = parameters["sequence"]
    if not isinstance(sequence_value, dict):
        raise ContractError("parameters.sequence must be an object")
    _exact_keys(
        sequence_value,
        {"schemaVersion", "frameRate", "durationFrames"},
        {"notes"},
        "parameters.sequence",
    )
    if not _is_int(sequence_value["schemaVersion"]) or sequence_value["schemaVersion"] != 1:
        raise ContractError("sequence.schemaVersion must be integer 1")
    if not _is_int(sequence_value["frameRate"]) or sequence_value["frameRate"] != FRAME_RATE:
        raise ContractError("sequence.frameRate must be integer 25")
    duration_frames = _integer(
        sequence_value["durationFrames"],
        label="sequence.durationFrames",
        low=1,
        high=MAX_DURATION_FRAMES,
    )
    if duration_seconds != duration_frames / FRAME_RATE:
        raise ContractError("durationSeconds must equal durationFrames / 25")

    notes: tuple[NoteEvent, ...] | None = None
    if "notes" in sequence_value:
        note_values = sequence_value["notes"]
        if not isinstance(note_values, list) or len(note_values) > MAX_NOTES:
            raise ContractError("sequence.notes must be an array of at most 512 notes")
        parsed: list[NoteEvent] = []
        for index, item in enumerate(note_values):
            if not isinstance(item, dict):
                raise ContractError(f"sequence.notes[{index}] must be an object")
            _exact_keys(
                item,
                {"pitch", "startFrame", "endFrame"},
                set(),
                f"sequence.notes[{index}]",
            )
            pitch = _integer(
                item["pitch"], label=f"sequence.notes[{index}].pitch", low=0, high=127
            )
            start = _integer(
                item["startFrame"],
                label=f"sequence.notes[{index}].startFrame",
                low=0,
                high=duration_frames - 1,
            )
            end = _integer(
                item["endFrame"],
                label=f"sequence.notes[{index}].endFrame",
                low=1,
                high=duration_frames,
            )
            if end <= start:
                raise ContractError(f"sequence.notes[{index}] must be a nonempty half-open interval")
            parsed.append(NoteEvent(pitch, start, end))
        parsed.sort(key=lambda note: (note.pitch, note.start_frame, note.end_frame))
        ends: dict[int, int] = {}
        for note in parsed:
            if note.start_frame < ends.get(note.pitch, 0):
                raise ContractError("notes must not overlap within a pitch")
            ends[note.pitch] = note.end_frame
        notes = tuple(parsed)

    sequence = NoteSequence(duration_frames, notes)
    # Preserve the complete accepted request as submitted. Canonical note order
    # belongs to condition metadata and its digest, not to the frozen request.
    snapshot = json.loads(json.dumps(value, ensure_ascii=False, allow_nan=False))
    return MRT2Request(snapshot, run_id, prompt, duration_seconds, seed, sequence)


def condition_frames(sequence: NoteSequence) -> Iterator[tuple[int, ...] | None]:
    if sequence.notes is None:
        for _ in range(sequence.duration_frames):
            yield None
        return
    starts: dict[int, list[NoteEvent]] = {}
    for note in sequence.notes:
        starts.setdefault(note.start_frame, []).append(note)
    active_ends: dict[int, int] = {}
    for frame_index in range(sequence.duration_frames):
        for pitch in tuple(active_ends):
            if active_ends[pitch] <= frame_index:
                del active_ends[pitch]
        values = [0] * NOTES_WIDTH
        for pitch in active_ends:
            values[pitch] = 1
        for note in starts.get(frame_index, ()):  # validated non-overlap per pitch
            active_ends[note.pitch] = note.end_frame
            values[note.pitch] = 2
        yield tuple(values)


def canonical_condition_bytes(request: MRT2Request) -> bytes:
    try:
        return json.dumps(
            request.condition_metadata(),
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as exc:
        raise ContractError(f"cannot encode canonical condition: {exc}", "output") from exc


def validate_manifest(value: dict[str, Any], *, expected: ManifestSpec = FIXED_MANIFEST) -> ManifestSpec:
    required = {"schemaVersion", "profile", "repository", "revision", "license", "files"}
    _exact_keys(value, required, set(), "manifest")
    if (
        not _is_int(value["schemaVersion"])
        or value["schemaVersion"] != expected.schema_version
        or value["profile"] != expected.profile
        or value["repository"] != expected.repository
        or value["revision"] != expected.revision
        or value["license"] != expected.license
    ):
        raise ContractError("manifest identity does not match the fixed MRT2 profile", "configuration")
    files = value["files"]
    if not isinstance(files, list) or len(files) != len(expected.files):
        raise ContractError("manifest must contain the fixed six files", "configuration")
    for index, (item, registered) in enumerate(zip(files, expected.files)):
        if not isinstance(item, dict):
            raise ContractError(f"manifest.files[{index}] must be an object", "configuration")
        _exact_keys(
            item,
            {"path", "size", "sha256"},
            set(),
            f"manifest.files[{index}]",
        )
        relative = item["path"]
        if (
            not isinstance(relative, str)
            or PurePosixPath(relative).is_absolute()
            or ".." in PurePosixPath(relative).parts
            or relative != registered.relative_path
            or not _is_int(item["size"])
            or item["size"] != registered.size
            or item["sha256"] != registered.sha256
        ):
            raise ContractError(
                f"manifest.files[{index}] does not match the registered path/size/SHA-256",
                "configuration",
            )
    return expected


def validate_launch_paths(
    request: Path, job: Path, model: Path, manifest: Path, vendor: Path
) -> None:
    labelled = (
        (request, "request"),
        (job, "job directory"),
        (model, "model directory"),
        (manifest, "manifest"),
        (vendor, "vendor directory"),
    )
    for path, label in labelled:
        ensure_no_symlink_components(path, label=label)
    for path, label in ((job, "job directory"), (model, "model directory"), (vendor, "vendor directory")):
        if not stat.S_ISDIR(os.lstat(path).st_mode):
            raise ContractError(f"{label} must be a directory", "configuration")
    for path, label in ((request, "request"), (manifest, "manifest")):
        if not stat.S_ISREG(os.lstat(path).st_mode):
            raise ContractError(f"{label} must be a regular file", "configuration")
    paths = [item[0] for item in labelled]
    for index, first in enumerate(paths):
        for second in paths[index + 1:]:
            if paths_overlap(first, second):
                raise ContractError("launch paths must not overlap", "configuration")
    try:
        with os.scandir(job) as entries:
            if next(entries, None) is not None:
                raise ContractError("job directory must be empty", "configuration")
    except OSError as exc:
        raise ContractError(f"cannot inspect job directory: {exc}", "configuration") from exc


def _file_identity(info: os.stat_result) -> tuple[int, int, int, int, int]:
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def _check_cancel(cancelled: Callable[[], bool], message: str) -> None:
    if cancelled():
        raise InterruptedError(message)


def verify_manifest_weights(
    manifest: ManifestSpec, model: Path, *, cancelled: Callable[[], bool]
) -> None:
    for entry in manifest.files:
        _check_cancel(cancelled, "cancelled during model verification")
        path = model.joinpath(*PurePosixPath(entry.relative_path).parts)
        ensure_no_symlink_components(path, label=f"weight {entry.relative_path}")
        try:
            leaf = os.lstat(path)
        except OSError as exc:
            raise ContractError(
                f"weight {entry.relative_path} is unavailable: {exc}", "configuration"
            ) from exc
        if not stat.S_ISREG(leaf.st_mode):
            raise ContractError(f"weight {entry.relative_path} must be a regular file", "configuration")
        flags = (
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0)
        )
        try:
            descriptor = os.open(path, flags)
        except OSError as exc:
            raise ContractError(f"cannot open weight {entry.relative_path}: {exc}", "configuration") from exc
        try:
            before = os.fstat(descriptor)
            if not stat.S_ISREG(before.st_mode) or before.st_size != entry.size:
                raise ContractError(f"weight {entry.relative_path} size mismatch", "configuration")
            digest = hashlib.sha256()
            total = 0
            while True:
                _check_cancel(cancelled, "cancelled during model verification")
                chunk = os.read(descriptor, 1 << 20)
                if not chunk:
                    break
                digest.update(chunk)
                total += len(chunk)
            after = os.fstat(descriptor)
            if (
                _file_identity(before) != _file_identity(after)
                or total != before.st_size
                or _file_identity(leaf) != _file_identity(before)
            ):
                raise ContractError(
                    f"weight {entry.relative_path} changed during verification", "configuration"
                )
            if digest.hexdigest() != entry.sha256:
                raise ContractError(f"weight {entry.relative_path} SHA-256 mismatch", "configuration")
        finally:
            os.close(descriptor)
        _check_cancel(cancelled, "cancelled during model verification")


def encode_float32_wave(samples: Iterable[float], frame_count: int) -> bytes:
    values = array("f")
    for value in samples:
        if isinstance(value, bool):
            raise ContractError("output contains a non-numeric sample", "output")
        try:
            number = float(value)
        except (TypeError, ValueError, OverflowError) as exc:
            raise ContractError("output contains a non-numeric sample", "output") from exc
        if not math.isfinite(number):
            raise ContractError("output contains NaN/Infinity", "output")
        values.append(number)
    if len(values) != frame_count * CHANNELS:
        raise ContractError("output sample count mismatch", "output")
    payload_values = array("f", values)
    if sys.byteorder != "little":
        payload_values.byteswap()
    payload = payload_values.tobytes()
    fmt = struct.pack(
        "<HHIIHH",
        3,
        CHANNELS,
        SAMPLE_RATE,
        SAMPLE_RATE * CHANNELS * 4,
        CHANNELS * 4,
        32,
    )
    riff_size = 4 + 8 + len(fmt) + 8 + len(payload)
    if riff_size > 0xFFFFFFFF:
        raise ContractError("output exceeds RIFF limit", "output")
    return (
        b"RIFF"
        + struct.pack("<I", riff_size)
        + b"WAVEfmt "
        + struct.pack("<I", len(fmt))
        + fmt
        + b"data"
        + struct.pack("<I", len(payload))
        + payload
    )


def validate_float32_wave(raw: bytes, *, expected_frames: int) -> str:
    expected_size = 44 + expected_frames * CHANNELS * 4
    if len(raw) != expected_size or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ContractError("output WAV container/frame validation failed", "output")
    if struct.unpack_from("<I", raw, 4)[0] + 8 != len(raw):
        raise ContractError("output WAV RIFF length mismatch", "output")
    if raw[12:16] != b"fmt " or struct.unpack_from("<I", raw, 16)[0] != 16:
        raise ContractError("output WAV must have a canonical fmt chunk", "output")
    tag, channels, rate, byte_rate, align, bits = struct.unpack_from("<HHIIHH", raw, 20)
    if (tag, channels, rate, byte_rate, align, bits) != (
        3,
        CHANNELS,
        SAMPLE_RATE,
        SAMPLE_RATE * CHANNELS * 4,
        CHANNELS * 4,
        32,
    ):
        raise ContractError("output WAV must be stereo 48000 Hz IEEE float32", "output")
    if raw[36:40] != b"data" or struct.unpack_from("<I", raw, 40)[0] != len(raw) - 44:
        raise ContractError("output WAV data length mismatch", "output")
    for (sample,) in struct.iter_unpack("<f", raw[44:]):
        if not math.isfinite(sample):
            raise ContractError("output WAV contains NaN/Infinity", "output")
    return hashlib.sha256(raw).hexdigest()
