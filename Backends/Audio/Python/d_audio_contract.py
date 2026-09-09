"""AUDIO1 standard-library validation, PCM, and publication helpers."""

from __future__ import annotations

from array import array
from dataclasses import dataclass
import errno
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import secrets
import stat
import struct
import sys
from typing import Any, Callable, Iterable
import uuid


SCHEMA_VERSION = 1
MAX_CONFIG_BYTES = 1024 * 1024
MAX_SOURCE_BYTES = 512 * 1024 * 1024
SAMPLE_RATE = 44_100
CHANNELS = 2
SAMPLES_PER_LATENT = 4096
MODEL_REPOSITORY = "stabilityai/stable-audio-3-optimized"
MODEL_REVISION = "da6edc54ddba10bfd79a077102ded687f80e882b"
VENDOR_REPOSITORY = "https://github.com/Stability-AI/stable-audio-3"
VENDOR_REVISION = "779434a908193105335fd8d833418603625b2859"
PROFILES = {
    "sm-music": (120.0, "dit_sm-music_f16.npz", "same_s"),
    "sm-sfx": (120.0, "dit_sm-sfx_f16.npz", "same_s"),
    "medium": (380.0, "dit_medium_f16.npz", "same_l"),
}


class ContractError(Exception):
    def __init__(self, message: str, kind: str = "invalidRequest") -> None:
        super().__init__(message)
        self.kind = kind


class DuplicateKeyError(ValueError):
    pass


@dataclass(frozen=True)
class SourceSpec:
    path: Path
    sha256: str
    frame_count: int
    sample_rate: int
    channels: int


@dataclass(frozen=True)
class EditRegion:
    start_frame: int
    end_frame: int


@dataclass(frozen=True)
class AudioRequest:
    raw: dict[str, Any]
    snapshot: dict[str, Any]
    run_id: str
    operation: str
    prompt: str
    duration_seconds: float
    requested_frames: int
    seed: int
    steps: int
    guidance_scale: float
    strength: float
    source: SourceSpec | None
    edit_region: EditRegion | None
    latent_count: int
    effective_latent_region: tuple[int, int] | None


@dataclass(frozen=True)
class WeightEntry:
    relative_path: str
    size: int
    sha256: str


@dataclass(frozen=True)
class WeightManifest:
    revision: str
    entries: tuple[WeightEntry, ...]

    @property
    def required_weight_bytes(self) -> int:
        return sum(item.size for item in self.entries)

    def provenance(self) -> list[dict[str, Any]]:
        return [
            {"path": item.relative_path, "size": item.size, "sha256": item.sha256}
            for item in self.entries
        ]


@dataclass
class WaveData:
    samples: array
    frame_count: int
    sample_rate: int
    channels: int
    source_encoding: str
    raw_bytes: bytes


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number {value!r} is forbidden")


def _finite_float(value: str) -> float:
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"non-finite JSON number {value!r} is forbidden")
    return result


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def decode_strict_json(raw: bytes, *, label: str) -> dict[str, Any]:
    try:
        value = json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
            parse_float=_finite_float,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, DuplicateKeyError, ValueError,
            OverflowError, RecursionError) as exc:
        raise ContractError(f"invalid {label} JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError(f"{label} root must be an object")
    stack: list[tuple[Any, int]] = [(value, 1)]
    while stack:
        current, depth = stack.pop()
        if depth > 32:
            raise ContractError(f"invalid {label} JSON: nesting exceeds 32 containers")
        if isinstance(current, dict):
            stack.extend((child, depth + 1) for child in current.values()
                         if isinstance(child, (dict, list)))
        elif isinstance(current, list):
            stack.extend((child, depth + 1) for child in current
                         if isinstance(child, (dict, list)))
    return value


def load_strict_json(path: Path, *, label: str) -> dict[str, Any]:
    raw, _ = read_regular_file(path, max_bytes=MAX_CONFIG_BYTES, label=label)
    return decode_strict_json(raw, label=label)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _exact_keys(value: dict[str, Any], required: set[str], optional: set[str], label: str) -> None:
    missing = required - value.keys()
    unknown = value.keys() - required - optional
    if missing:
        raise ContractError(f"{label} is missing keys: {', '.join(sorted(missing))}")
    if unknown:
        raise ContractError(f"{label} has unknown keys: {', '.join(sorted(unknown))}")


def _integer(value: Any, label: str, low: int, high: int) -> int:
    if not _is_int(value) or not low <= value <= high:
        raise ContractError(f"{label} must be an integer in {low}...{high}")
    return value


def _number(value: Any, label: str, low: float, high: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ContractError(f"{label} must be a finite number")
    try:
        result = float(value)
    except (OverflowError, ValueError) as exc:
        raise ContractError(f"{label} cannot be represented as a finite number") from exc
    if not math.isfinite(result) or result < low or (high is not None and result > high):
        raise ContractError(f"{label} is outside its finite allowed range")
    return result


def checked_absolute_path(raw: Any, *, label: str) -> Path:
    if not isinstance(raw, str) or not raw or "\x00" in raw:
        raise ContractError(f"{label} must be a nonempty absolute path", "configuration")
    pure = PurePosixPath(raw)
    if not pure.is_absolute() or ".." in pure.parts:
        raise ContractError(f"{label} must be absolute and contain no '..' component", "configuration")
    normalized_text = os.path.normpath(raw)
    if normalized_text != raw:
        raise ContractError(f"{label} must already be normalized", "configuration")
    return Path(normalized_text)


def ensure_no_symlink_components(path: Path, *, label: str, allow_missing_leaf: bool = False) -> None:
    if not path.is_absolute():
        raise ContractError(f"{label} must be absolute", "configuration")
    current = Path(path.anchor)
    parts = path.parts[1:]
    for index, part in enumerate(parts):
        current /= part
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            if allow_missing_leaf and index == len(parts) - 1:
                return
            raise ContractError(f"{label} does not exist: {current}", "configuration") from None
        if stat.S_ISLNK(info.st_mode):
            raise ContractError(f"{label} contains a symbolic-link component: {current}", "configuration")


def _identity(info: os.stat_result) -> tuple[int, int, int, int, int]:
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def read_regular_file(path: Path, *, max_bytes: int | None, label: str) -> tuple[bytes, tuple[int, int, int, int, int]]:
    ensure_no_symlink_components(path, label=label)
    if not stat.S_ISREG(os.lstat(path).st_mode):
        raise ContractError(f"{label} must be a regular file", "configuration")
    flags = (os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) |
             getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ContractError(f"cannot open {label}: {exc}", "configuration") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ContractError(f"{label} must be a regular file", "configuration")
        if max_bytes is not None and before.st_size > max_bytes:
            raise ContractError(f"{label} exceeds {max_bytes} bytes", "configuration")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if max_bytes is not None and total > max_bytes:
                raise ContractError(f"{label} exceeds {max_bytes} bytes", "configuration")
            chunks.append(chunk)
        after = os.fstat(descriptor)
        if _identity(before) != _identity(after) or total != before.st_size:
            raise ContractError(f"{label} changed while being read", "configuration")
        return b"".join(chunks), _identity(before)
    finally:
        os.close(descriptor)


def hash_regular_file(path: Path, *, expected_size: int | None, label: str) -> str:
    ensure_no_symlink_components(path, label=label)
    if not stat.S_ISREG(os.lstat(path).st_mode):
        raise ContractError(f"{label} must be a regular file", "configuration")
    flags = (os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) |
             getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ContractError(f"cannot open {label}: {exc}", "configuration") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ContractError(f"{label} must be a regular file", "configuration")
        if expected_size is not None and before.st_size != expected_size:
            raise ContractError(f"{label} size mismatch", "configuration")
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            digest.update(chunk)
        after = os.fstat(descriptor)
        if _identity(before) != _identity(after) or total != before.st_size:
            raise ContractError(f"{label} changed during verification", "configuration")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def path_contains(parent: Path, child: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def paths_overlap(first: Path, second: Path) -> bool:
    return path_contains(first, second) or path_contains(second, first)


def validate_launch_paths(request: Path, job: Path, model: Path, manifest: Path, vendor: Path) -> None:
    for path, label in ((request, "request"), (job, "job directory"), (model, "model directory"),
                        (manifest, "manifest"), (vendor, "vendor directory")):
        ensure_no_symlink_components(path, label=label)
    for path, label in ((job, "job directory"), (model, "model directory"), (vendor, "vendor directory")):
        if not stat.S_ISDIR(os.lstat(path).st_mode):
            raise ContractError(f"{label} must be a directory", "configuration")
    for path, label in ((request, "request"), (manifest, "manifest")):
        if not stat.S_ISREG(os.lstat(path).st_mode):
            raise ContractError(f"{label} must be a regular file", "configuration")
    if paths_overlap(job, model) or paths_overlap(job, vendor):
        raise ContractError("job directory must be separate from model/vendor", "configuration")
    if paths_overlap(model, vendor):
        raise ContractError("model and vendor must not contain one another", "configuration")
    if path_contains(job, request) or path_contains(job, manifest):
        raise ContractError("request and manifest must be outside job", "configuration")
    with os.scandir(job) as entries:
        if next(entries, None) is not None:
            raise ContractError("job directory must be empty", "configuration")


def validate_source_relationships(source: SourceSpec, request: Path, job: Path, model: Path, manifest: Path, vendor: Path) -> None:
    ensure_no_symlink_components(source.path, label="source")
    if path_contains(job, source.path) or source.path in (request, manifest):
        raise ContractError("source must be outside job and distinct from config files")
    if path_contains(model, source.path) or path_contains(vendor, source.path):
        raise ContractError("source must not be inside model/vendor")


def validate_request(value: dict[str, Any], *, profile: str) -> AudioRequest:
    if profile not in PROFILES:
        raise ContractError(f"unsupported profile {profile!r}", "configuration")
    required = {"schemaVersion", "runID", "operation", "prompt", "durationSeconds", "seed", "steps", "guidanceScale", "strength"}
    _exact_keys(value, required, {"source", "editRegion"}, "request")
    if not _is_int(value["schemaVersion"]) or value["schemaVersion"] != SCHEMA_VERSION:
        raise ContractError("request schemaVersion must be integer 1")
    run_id = value["runID"]
    try:
        if not isinstance(run_id, str) or str(uuid.UUID(run_id)) != run_id:
            raise ValueError
    except (ValueError, AttributeError):
        raise ContractError("runID must be a lowercase canonical UUID") from None
    operation = value["operation"]
    if operation not in ("generate", "variation", "inpaint"):
        raise ContractError("operation must be generate, variation, or inpaint")
    prompt = value["prompt"]
    if not isinstance(prompt, str):
        raise ContractError("prompt must be Unicode text")
    try:
        prompt_size = len(prompt.encode("utf-8", errors="strict"))
    except UnicodeEncodeError as exc:
        raise ContractError("prompt contains an invalid Unicode surrogate") from exc
    if prompt_size > MAX_CONFIG_BYTES:
        raise ContractError("prompt exceeds 1 MiB UTF-8")
    duration = _number(value["durationSeconds"], "durationSeconds", 0.0)
    if duration <= 0 or duration > PROFILES[profile][0]:
        raise ContractError(f"durationSeconds exceeds {profile} limit")
    requested_frames = round(duration * SAMPLE_RATE)
    if requested_frames <= 0:
        raise ContractError("durationSeconds rounds to zero frames")
    seed = _integer(value["seed"], "seed", 0, 2**32 - 2)
    steps = _integer(value["steps"], "steps", 1, 100)
    guidance = _number(value["guidanceScale"], "guidanceScale", 1.0, 15.0)
    strength = _number(value["strength"], "strength", 0.01, 1.0)
    source: SourceSpec | None = None
    if "source" in value:
        item = value["source"]
        if not isinstance(item, dict):
            raise ContractError("source must be an object")
        _exact_keys(item, {"path", "sha256", "frameCount", "sampleRate", "channels"}, set(), "source")
        digest = item["sha256"]
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ContractError("source.sha256 must be 64 lowercase hexadecimal")
        source = SourceSpec(
            checked_absolute_path(item["path"], label="source.path"), digest,
            _integer(item["frameCount"], "source.frameCount", 1, 2**63 - 1),
            _integer(item["sampleRate"], "source.sampleRate", SAMPLE_RATE, SAMPLE_RATE),
            _integer(item["channels"], "source.channels", CHANNELS, CHANNELS),
        )
    region: EditRegion | None = None
    if "editRegion" in value:
        item = value["editRegion"]
        if not isinstance(item, dict):
            raise ContractError("editRegion must be an object")
        _exact_keys(item, {"startFrame", "endFrame"}, set(), "editRegion")
        region = EditRegion(
            _integer(item["startFrame"], "editRegion.startFrame", 0, 2**63 - 1),
            _integer(item["endFrame"], "editRegion.endFrame", 1, 2**63 - 1),
        )
        if region.start_frame >= region.end_frame:
            raise ContractError("editRegion must be a nonempty half-open range")
    if operation == "generate" and (source is not None or region is not None or strength != 1.0):
        raise ContractError("generate requires no source/editRegion and strength 1")
    if operation == "variation" and (source is None or region is not None):
        raise ContractError("variation requires source and forbids editRegion")
    if operation == "inpaint" and (source is None or region is None):
        raise ContractError("inpaint requires source and editRegion")
    if source is not None:
        if abs(duration * SAMPLE_RATE - source.frame_count) > 0.5:
            raise ContractError("durationSeconds does not match source frames within half a sample")
        requested_frames = source.frame_count
        if region is not None and region.end_frame > source.frame_count:
            raise ContractError("editRegion is outside source")
    latent_count = max(1, math.ceil(duration * SAMPLE_RATE / SAMPLES_PER_LATENT))
    effective = None
    if region is not None:
        effective = (max(0, round(region.start_frame / SAMPLES_PER_LATENT)),
                     min(latent_count, round(region.end_frame / SAMPLES_PER_LATENT)))
        if effective[0] >= effective[1]:
            raise ContractError("editRegion rounds to an empty latent interval")
    snapshot = json.loads(json.dumps(value, ensure_ascii=False))
    if source is not None:
        snapshot["source"] = {"sha256": source.sha256, "frameCount": source.frame_count,
                              "sampleRate": source.sample_rate, "channels": source.channels}
    return AudioRequest(value, snapshot, run_id, operation, prompt, duration, requested_frames,
                        seed, steps, guidance, strength, source, region, latent_count, effective)


def required_weight_names(profile: str) -> tuple[str, ...]:
    if profile not in PROFILES:
        raise ContractError(f"unsupported profile {profile!r}", "configuration")
    _cap, dit, codec = PROFILES[profile]
    return (f"MLX/{dit}", "MLX/t5gemma_f16.npz", f"MLX/{codec}_decoder_f32.npz", f"MLX/{codec}_encoder_f32.npz")


def validate_manifest(value: dict[str, Any], *, profile: str) -> WeightManifest:
    _exact_keys(value, {"schemaVersion", "repository", "revision", "files"}, set(), "manifest")
    if not _is_int(value["schemaVersion"]) or value["schemaVersion"] != 1:
        raise ContractError("manifest schemaVersion must be integer 1", "configuration")
    if value["repository"] != MODEL_REPOSITORY or value["revision"] != MODEL_REVISION:
        raise ContractError("manifest repository/revision is not registered", "configuration")
    expected = required_weight_names(profile)
    files = value["files"]
    if not isinstance(files, list) or len(files) != 4:
        raise ContractError("manifest must contain exactly four files", "configuration")
    found: dict[str, WeightEntry] = {}
    for index, item in enumerate(files):
        if not isinstance(item, dict):
            raise ContractError(f"manifest.files[{index}] must be an object", "configuration")
        _exact_keys(item, {"path", "size", "sha256"}, set(), f"manifest.files[{index}]")
        relative, size, digest = item["path"], item["size"], item["sha256"]
        if relative not in expected or PurePosixPath(relative).is_absolute() or ".." in PurePosixPath(relative).parts:
            raise ContractError(f"untrusted manifest path {relative!r}", "configuration")
        if relative in found:
            raise ContractError(f"duplicate manifest path {relative!r}", "configuration")
        if not _is_int(size) or size <= 0:
            raise ContractError("manifest size must be a positive integer", "configuration")
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ContractError("manifest sha256 must be 64 lowercase hexadecimal", "configuration")
        found[relative] = WeightEntry(relative, size, digest)
    if set(found) != set(expected):
        raise ContractError("manifest does not match exact profile weights", "configuration")
    return WeightManifest(value["revision"], tuple(found[name] for name in expected))


def verify_manifest_weights(manifest: WeightManifest, model: Path) -> None:
    for entry in manifest.entries:
        path = model.joinpath(*PurePosixPath(entry.relative_path).parts)
        digest = hash_regular_file(path, expected_size=entry.size, label=f"weight {entry.relative_path}")
        if digest != entry.sha256:
            raise ContractError(f"weight digest mismatch: {entry.relative_path}", "configuration")


def estimate_peak_bytes(manifest: WeightManifest, duration: float) -> int:
    return 2 * max(item.size for item in manifest.entries) + (1 << 30) + math.ceil(duration) * (64 << 20)


def read_source_wave(spec: SourceSpec) -> WaveData:
    raw, identity = read_regular_file(spec.path, max_bytes=MAX_SOURCE_BYTES, label="source")
    digest = hashlib.sha256(raw).hexdigest()
    if digest != spec.sha256:
        raise ContractError("source SHA-256 does not match request")
    if hash_regular_file(spec.path, expected_size=len(raw), label="source") != digest:
        raise ContractError("source changed across verification reads")
    if _identity(os.stat(spec.path, follow_symlinks=False)) != identity:
        raise ContractError("source metadata changed across verification reads")
    wave = decode_wave_bytes(raw)
    if wave.frame_count != spec.frame_count:
        raise ContractError("source frameCount mismatch")
    if wave.sample_rate != spec.sample_rate or wave.channels != spec.channels:
        raise ContractError("source sampleRate/channels mismatch")
    return wave


def decode_wave_bytes(raw: bytes) -> WaveData:
    if len(raw) < 12 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ContractError("not a RIFF/WAVE file")
    if struct.unpack_from("<I", raw, 4)[0] + 8 != len(raw):
        raise ContractError("RIFF declared length mismatch")
    offset, fmt, data = 12, None, None
    while offset < len(raw):
        if offset + 8 > len(raw):
            raise ContractError("truncated RIFF chunk header")
        chunk_id, size = raw[offset:offset + 4], struct.unpack_from("<I", raw, offset + 4)[0]
        start, end = offset + 8, offset + 8 + size
        padded_end = end + (size & 1)
        if end > len(raw) or padded_end > len(raw):
            raise ContractError("truncated RIFF chunk")
        if chunk_id == b"fmt ":
            if fmt is not None:
                raise ContractError("duplicate fmt chunk")
            fmt = raw[start:end]
        elif chunk_id == b"data":
            if data is not None:
                raise ContractError("duplicate data chunk")
            data = raw[start:end]
        offset = padded_end
    if offset != len(raw) or fmt is None or data is None or len(fmt) < 16:
        raise ContractError("WAVE requires complete fmt and data chunks")
    tag, channels, rate, byte_rate, align, bits = struct.unpack_from("<HHIIHH", fmt, 0)
    if channels != CHANNELS or rate != SAMPLE_RATE:
        raise ContractError("source must be stereo 44100 Hz; conversion is forbidden")
    if bits not in (16, 24, 32) or align != channels * (bits // 8) or byte_rate != rate * align:
        raise ContractError("unsupported or inconsistent WAVE format/alignment")
    if not data or len(data) % align:
        raise ContractError("WAVE data is empty or misaligned")
    if tag == 1 and bits in (16, 24, 32):
        encoding = f"int{bits}"
    elif tag == 3 and bits == 32:
        encoding = "float32"
    else:
        raise ContractError("only LPCM int16/int24/int32 and IEEE float32 are supported")
    samples = array("f")
    if encoding == "int16":
        samples.extend(sample / 32768.0 for (sample,) in struct.iter_unpack("<h", data))
    elif encoding == "int24":
        for index in range(0, len(data), 3):
            value = data[index] | data[index + 1] << 8 | data[index + 2] << 16
            if value & 0x800000:
                value -= 1 << 24
            samples.append(value / 8388608.0)
    elif encoding == "int32":
        samples.extend(sample / 2147483648.0 for (sample,) in struct.iter_unpack("<i", data))
    else:
        for (sample,) in struct.iter_unpack("<f", data):
            if not math.isfinite(sample):
                raise ContractError("float32 source contains NaN/Infinity")
            samples.append(sample)
    frames = len(data) // align
    if len(samples) != frames * CHANNELS:
        raise ContractError("decoded PCM count mismatch")
    return WaveData(samples, frames, rate, channels, encoding, raw)


def encode_float32_wave(samples: Iterable[float], frame_count: int) -> bytes:
    values = array("f")
    for value in samples:
        number = float(value)
        if not math.isfinite(number):
            raise ContractError("output contains NaN/Infinity", "output")
        values.append(number)
    if len(values) != frame_count * CHANNELS:
        raise ContractError("output sample count mismatch", "output")
    payload_values = array("f", values)
    if sys.byteorder != "little":
        payload_values.byteswap()
    payload = payload_values.tobytes()
    fmt = struct.pack("<HHIIHH", 3, CHANNELS, SAMPLE_RATE, SAMPLE_RATE * CHANNELS * 4, CHANNELS * 4, 32)
    riff_size = 4 + 8 + len(fmt) + 8 + len(payload)
    if riff_size > 0xFFFFFFFF:
        raise ContractError("output exceeds RIFF limit", "output")
    return b"RIFF" + struct.pack("<I", riff_size) + b"WAVEfmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(payload)) + payload


def preserve_inpaint_outside(
    generated: Iterable[float], source: WaveData, region: EditRegion
) -> array:
    generated_values = array("f", generated)
    if len(generated_values) != source.frame_count * CHANNELS:
        raise ContractError("inpaint output sample count mismatch", "output")
    result = array("f", source.samples)
    first = region.start_frame * CHANNELS
    last = region.end_frame * CHANNELS
    result[first:last] = generated_values[first:last]
    return result


def validate_float32_output(raw: bytes, expected_frames: int) -> str:
    wave = decode_wave_bytes(raw)
    if wave.source_encoding != "float32" or wave.frame_count != expected_frames:
        raise ContractError("output WAV format/frame validation failed", "output")
    return hashlib.sha256(raw).hexdigest()


def publish_exclusive(job: Path, filename: str, content: bytes, *, validate: Callable[[bytes], Any] | None = None) -> Path:
    if not filename or "/" in filename or filename in (".", ".."):
        raise ContractError("invalid owned filename", "output")
    target = job / filename
    if os.path.lexists(target):
        raise ContractError(f"refusing to overwrite {filename}", "output")
    partial = job / f".{filename}.{secrets.token_hex(8)}.partial"
    descriptor: int | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(partial, flags, 0o600)
        view, written = memoryview(content), 0
        while written < len(view):
            count = os.write(descriptor, view[written:])
            if count <= 0:
                raise OSError(errno.EIO, "short write")
            written += count
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        reread, _ = read_regular_file(partial, max_bytes=len(content), label=f"partial {filename}")
        if reread != content:
            raise ContractError(f"partial {filename} byte mismatch", "output")
        if validate is not None:
            validate(reread)
        os.link(partial, target, follow_symlinks=False)
        directory_fd = os.open(job, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        os.unlink(partial)
        return target
    except FileExistsError as exc:
        raise ContractError(f"refusing to overwrite {filename}", "output") from exc
    except ContractError:
        raise
    except OSError as exc:
        raise ContractError(f"failed to publish {filename}: {exc}", "output") from exc
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if os.path.lexists(partial):
            try:
                os.unlink(partial)
            except OSError:
                pass


def json_bytes(value: dict[str, Any]) -> bytes:
    try:
        return (json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as exc:
        raise ContractError(f"cannot encode finite result JSON: {exc}", "output") from exc
