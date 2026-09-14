#!/usr/bin/env python3
"""Strict SwiftF0 0.1.2 CPU provider for D's prepared mono-16k input."""

from __future__ import annotations

import argparse
from contextlib import nullcontext
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import stat
import struct
import sys
import time
from typing import Any, Callable, ContextManager, Sequence
import uuid


MODEL_SHA256 = "fa91bb45512b90339cf4b00a599ba8fe3a253c46419fcfe6b46df77a8a8336a5"
PROFILE = "swift-f0-0.1.2-cpu-v1"
PREPROCESSING = "avconverter-mono16k-prime-normal-v1"
PROVIDER = "swift-f0-0.1.2/onnxruntime-cpu"
MAX_REQUEST_BYTES = 1024 * 1024
MAX_INPUT_BYTES = 7_680_000
MIN_SAMPLES = 256
MAX_SAMPLES = 1_920_000
HOP = 256
FMIN = 46.875
FMAX = 2093.75
THRESHOLD = 0.9


class ProtocolError(Exception):
    pass


class _DuplicateKey(ValueError):
    pass


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateKey("duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(_value: str) -> None:
    raise ValueError("non-finite JSON number")


def _exact(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ProtocolError(f"{label} has invalid fields")
    return value


def _integer(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ProtocolError(f"{label} must be an integer")
    return value


def _path(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ProtocolError(f"{label} must be a normalized absolute path")
    pure = PurePosixPath(value)
    if pure.anchor != "/" or ".." in pure.parts or os.path.normpath(value) != value:
        raise ProtocolError(f"{label} must be a normalized absolute path")
    return Path(value)


def _digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise ProtocolError(f"{label} must be a lowercase SHA-256")
    return value


def _uuid(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise ProtocolError(f"{label} must be a UUID")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError, TypeError) as exc:
        raise ProtocolError(f"{label} must be a UUID") from exc
    if value != str(parsed):
        raise ProtocolError(f"{label} must be a canonical lowercase UUID")
    return value


def _file_identity(info: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def _open_regular_without_symlinks(path: Path, label: str) -> tuple[int, os.stat_result]:
    path = _path(str(path), label)
    search_flags = os.O_SEARCH | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    leaf_flags = (os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                  | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        directory = os.open(path.anchor, search_flags)
    except OSError as exc:
        raise ProtocolError(f"{label} cannot be traversed safely") from exc
    try:
        for component in path.parts[1:-1]:
            try:
                child = os.open(component, search_flags, dir_fd=directory)
            except OSError as exc:
                raise ProtocolError(f"{label} has a linked or unavailable parent") from exc
            os.close(directory)
            directory = child
        try:
            named = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
            descriptor = os.open(path.name, leaf_flags, dir_fd=directory)
        except OSError as exc:
            raise ProtocolError(f"{label} cannot be opened safely") from exc
        try:
            opened = os.fstat(descriptor)
        except OSError as exc:
            os.close(descriptor)
            raise ProtocolError(f"{label} identity cannot be verified") from exc
        if (not stat.S_ISREG(named.st_mode) or not stat.S_ISREG(opened.st_mode)
                or _file_identity(named) != _file_identity(opened)):
            os.close(descriptor)
            raise ProtocolError(f"{label} must be one unchanged regular nonsymlink file")
        return descriptor, opened
    finally:
        os.close(directory)


def _bounded_regular_bytes(path: Path, maximum: int, label: str,
                           expected_size: int | None = None) -> bytes:
    descriptor, before = _open_regular_without_symlinks(path, label)
    try:
        chunks: list[bytes] = []
        total = 0
        while total <= maximum:
            chunk = os.read(descriptor, min(64 * 1024, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        after = os.fstat(descriptor)
    except OSError as exc:
        raise ProtocolError(f"{label} cannot be read") from exc
    finally:
        os.close(descriptor)
    if total > maximum:
        raise ProtocolError(f"{label} exceeds its bounded size")
    if _file_identity(before) != _file_identity(after) or total != before.st_size:
        raise ProtocolError(f"{label} changed while being read")
    if expected_size is not None and total != expected_size:
        raise ProtocolError(f"{label} size does not match the request")
    return b"".join(chunks)


def _read_strict_json(path: Path) -> dict[str, Any]:
    raw = _bounded_regular_bytes(path, MAX_REQUEST_BYTES, "request file")
    if not raw or len(raw) > MAX_REQUEST_BYTES:
        raise ProtocolError("request file has an invalid bounded size")
    try:
        value = json.loads(raw.decode("utf-8", errors="strict"), object_pairs_hook=_unique_object,
                           parse_constant=_reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError, _DuplicateKey, ValueError,
            OverflowError, RecursionError) as exc:
        raise ProtocolError("request is not strict UTF-8 JSON") from exc
    return _validate_request(value)


def _validate_request(value: Any) -> dict[str, Any]:
    request = _exact(value, {
        "schemaVersion", "runID", "source", "profile", "preprocessing",
        "modelSHA256", "inputSHA256", "sampleCount", "inputPath",
        "modelDirectory", "runDirectory",
    }, "request")
    if _integer(request["schemaVersion"], "schemaVersion") != 1:
        raise ProtocolError("unsupported request schemaVersion")
    request["runID"] = _uuid(request["runID"], "runID")
    if request["profile"] != PROFILE or request["preprocessing"] != PREPROCESSING:
        raise ProtocolError("request profile or preprocessing is unsupported")
    if _digest(request["modelSHA256"], "modelSHA256") != MODEL_SHA256:
        raise ProtocolError("request model digest is unsupported")
    request["inputSHA256"] = _digest(request["inputSHA256"], "inputSHA256")
    count = _integer(request["sampleCount"], "sampleCount")
    if not MIN_SAMPLES <= count <= MAX_SAMPLES:
        raise ProtocolError("sampleCount is outside the fixed profile")
    request["inputPath"] = _path(request["inputPath"], "inputPath")
    request["modelDirectory"] = _path(request["modelDirectory"], "modelDirectory")
    request["runDirectory"] = _path(request["runDirectory"], "runDirectory")
    source = _exact(request["source"], {
        "assetID", "documentID", "documentRevision", "contentSHA256",
        "sampleRate", "frameCount", "startFrame", "endFrame",
    }, "source")
    source["assetID"] = _uuid(source["assetID"], "source.assetID")
    source["documentID"] = _uuid(source["documentID"], "source.documentID")
    source["documentRevision"] = _integer(source["documentRevision"], "source.documentRevision")
    source["contentSHA256"] = _digest(source["contentSHA256"], "source.contentSHA256")
    for name in ("frameCount", "startFrame", "endFrame"):
        source[name] = _integer(source[name], f"source.{name}")
    rate = source["sampleRate"]
    if isinstance(rate, bool) or not isinstance(rate, (int, float)) or not math.isfinite(rate):
        raise ProtocolError("source.sampleRate must be finite")
    source["sampleRate"] = float(rate)
    if not (8000 <= source["sampleRate"] <= 192000 and source["frameCount"] > 0
            and 0 <= source["startFrame"] < source["endFrame"] <= source["frameCount"]):
        raise ProtocolError("source identity or range is invalid")
    expected = (source["endFrame"] - source["startFrame"]) * 16000 / source["sampleRate"]
    if not MIN_SAMPLES <= expected <= MAX_SAMPLES or abs(count - expected) > 1:
        raise ProtocolError("sampleCount does not match the source range")
    return request


def _regular_bytes(path: Path, expected_size: int | None, maximum: int, label: str) -> bytes:
    return _bounded_regular_bytes(path, maximum, label, expected_size)


def _load_core(model_directory: Path) -> type[Any]:
    core_path = model_directory / "core.py"
    if core_path.parent != model_directory or core_path.is_symlink():
        raise ProtocolError("SwiftF0 core path is invalid")
    spec = importlib.util.spec_from_file_location("_d_pinned_swift_f0_core", core_path)
    if spec is None or spec.loader is None:
        raise ProtocolError("SwiftF0 core cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(spec.name, None)
        raise
    actual = Path(module.__file__).resolve(strict=True)
    if actual != core_path.resolve(strict=True) or actual.parent != model_directory.resolve(strict=True):
        raise ProtocolError("loaded SwiftF0 core does not match modelDirectory")
    swift_f0 = getattr(module, "SwiftF0", None)
    if not isinstance(swift_f0, type):
        raise ProtocolError("SwiftF0 core does not expose SwiftF0")
    return swift_f0


def _validated_frames(raw_pitch: Sequence[Any], raw_confidence: Sequence[Any],
                      raw_voicing: Sequence[Any], expected_count: int) -> list[dict[str, Any]]:
    for values in (raw_pitch, raw_confidence, raw_voicing):
        if getattr(values, "ndim", 1) != 1:
            raise ProtocolError("model outputs must be one-dimensional")
    if len(raw_pitch) != expected_count or len(raw_confidence) != expected_count or len(raw_voicing) != expected_count:
        raise ProtocolError("model output shape does not match floor(sampleCount/256)")
    frames: list[dict[str, Any]] = []
    for pitch_value, confidence_value, voicing_value in zip(raw_pitch, raw_confidence, raw_voicing):
        if isinstance(pitch_value, bool) or isinstance(confidence_value, bool):
            raise ProtocolError("model pitch and confidence outputs must be numeric, not Boolean")
        pitch = float(pitch_value)
        confidence = float(confidence_value)
        if not math.isfinite(pitch) or not math.isfinite(confidence) or not 0 <= confidence <= 1:
            raise ProtocolError("model output contains a non-finite pitch or invalid confidence")
        if not isinstance(voicing_value, (bool,)) and type(voicing_value).__name__ != "bool_":
            raise ProtocolError("model voicing output is not Boolean")
        voiced = confidence > THRESHOLD and FMIN <= pitch <= FMAX
        if bool(voicing_value) != voiced:
            raise ProtocolError("model voicing output contradicts the frozen predicate")
        frames.append({"rawPitchHz": pitch, "confidence": confidence, "voiced": voiced})
    return frames


def _analyze(request: dict[str, Any], detector_factory: Callable[[Path], Any] | None = None) -> dict[str, Any]:
    input_bytes = _regular_bytes(request["inputPath"], request["sampleCount"] * 4,
                                 MAX_INPUT_BYTES, "prepared input")
    if hashlib.sha256(input_bytes).hexdigest() != request["inputSHA256"]:
        raise ProtocolError("prepared input digest does not match the request")
    for (sample,) in struct.iter_unpack("<f", input_bytes):
        if not math.isfinite(sample):
            raise ProtocolError("prepared input contains a non-finite sample")
    model_bytes = _regular_bytes(request["modelDirectory"] / "model.onnx", 399_114,
                                 399_114, "SwiftF0 model")
    if hashlib.sha256(model_bytes).hexdigest() != MODEL_SHA256:
        raise ProtocolError("SwiftF0 model digest does not match the fixed contract")
    started = time.monotonic()
    if detector_factory is None:
        import numpy as np
        swift_f0 = _load_core(request["modelDirectory"])
        detector = swift_f0(confidence_threshold=THRESHOLD, fmin=FMIN, fmax=FMAX)
        audio = np.frombuffer(input_bytes, dtype="<f4").copy()
    else:
        detector = detector_factory(request["modelDirectory"])
        audio = [sample for (sample,) in struct.iter_unpack("<f", input_bytes)]
    result = detector.detect_from_array(audio, 16000)
    frames = _validated_frames(result.pitch_hz, result.confidence, result.voicing,
                               request["sampleCount"] // HOP)
    timestamps = result.timestamps
    if getattr(timestamps, "ndim", 1) != 1 or len(timestamps) != len(frames):
        raise ProtocolError("model timestamp shape does not match pitch frames")
    for index, timestamp_value in enumerate(timestamps):
        timestamp = float(timestamp_value)
        expected_timestamp = (HOP * index + 127.5) / 16000
        if not math.isfinite(timestamp) or abs(timestamp - expected_timestamp) > 1e-12:
            raise ProtocolError("model timestamps contradict the fixed frame-center contract")
    elapsed = time.monotonic() - started
    if not math.isfinite(elapsed) or elapsed < 0:
        raise ProtocolError("analysis timing is invalid")
    return {
        "schemaVersion": 1, "runID": request["runID"], "source": request["source"],
        "profile": PROFILE, "preprocessing": PREPROCESSING,
        "modelSHA256": MODEL_SHA256, "inputSHA256": request["inputSHA256"],
        "sampleCount": request["sampleCount"], "frames": frames,
        "metadata": {"profile": PROFILE, "modelSHA256": MODEL_SHA256,
                     "provider": PROVIDER, "analysisSeconds": elapsed},
    }


def _default_access_acquirer(manifest: Path, run_id: str,
                             directories: list[Path]) -> ContextManager[None]:
    helper = Path(__file__).resolve(strict=True).with_name("d_audio_access.py")
    spec = importlib.util.spec_from_file_location("_d_pitch_audio_access", helper)
    if spec is None or spec.loader is None:
        raise ProtocolError("audio access helper is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(spec.name, None)
        raise
    if Path(module.__file__).resolve(strict=True).parent != Path(__file__).resolve(strict=True).parent:
        raise ProtocolError("audio access helper is not the provider sibling")
    return module.acquire_file_access(manifest, run_id=run_id, allowed_paths=directories)


def _access_context(args: argparse.Namespace,
                    acquirer: Callable[[Path, str, list[Path]], ContextManager[None]] | None = None
                    ) -> tuple[ContextManager[None], list[Path] | None]:
    if (args.access_manifest is None) != (args.access_run_id is None):
        raise ProtocolError("access manifest and run ID must be supplied together")
    if args.access_manifest is None:
        if any(value is not None for value in
               (args.model_directory, args.input_directory, args.run_directory)):
            raise ProtocolError("access directories require an access manifest")
        return nullcontext(), None
    run_id = _uuid(args.access_run_id, "access run ID")
    if any(value is None for value in
           (args.model_directory, args.input_directory, args.run_directory)):
        raise ProtocolError("sandbox access requires three explicit directories")
    directories = [_path(args.model_directory, "model access directory"),
                   _path(args.input_directory, "input access directory"),
                   _path(args.run_directory, "run access directory")]
    acquire = acquirer or _default_access_acquirer
    return acquire(_path(args.access_manifest, "access manifest"), run_id, directories), directories


def _execute(args: argparse.Namespace,
             access_acquirer: Callable[[Path, str, list[Path]], ContextManager[None]] | None = None,
             analyzer: Callable[[dict[str, Any]], dict[str, Any]] = _analyze) -> dict[str, Any]:
    access, directories = _access_context(args, access_acquirer)
    # The manifest lives in the bootstrap cwd and is readable before acquiring grants;
    # request.json lives in the granted run directory and is intentionally opened inside.
    with access:
        request = _read_strict_json(_path(args.request, "request path"))
        if args.access_manifest is not None:
            assert directories is not None
            if (request["runID"] != args.access_run_id
                    or request["modelDirectory"] != directories[0]
                    or request["inputPath"].parent != directories[1]
                    or request["runDirectory"] != directories[2]):
                raise ProtocolError("granted paths or run ID do not match the frozen request")
        return analyzer(request)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--request", required=True)
    parser.add_argument("--access-manifest")
    parser.add_argument("--access-run-id")
    parser.add_argument("--model-directory")
    parser.add_argument("--input-directory")
    parser.add_argument("--run-directory")
    args = parser.parse_args(argv)
    try:
        response = _execute(args)
        encoded = json.dumps(response, ensure_ascii=False, allow_nan=False,
                             sort_keys=True, separators=(",", ":"))
        sys.stdout.write(encoded + "\n")
        sys.stdout.flush()
        return 0
    except BaseException as exc:
        message = str(exc) if isinstance(exc, (ProtocolError, ValueError, OSError)) else type(exc).__name__
        sys.stderr.write(f"pitch provider failed: {message}\n")
        sys.stderr.flush()
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
