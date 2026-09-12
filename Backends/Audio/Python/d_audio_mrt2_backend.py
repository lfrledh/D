#!/usr/bin/env python3
"""JSON-lines provider for the fixed MRT2-small exported profile."""

from __future__ import annotations

from array import array
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import sys
import time
from typing import Any, Callable, Sequence
import uuid

from d_audio_access import AudioAccessError, acquire_file_access
from d_audio_contract import ContractError, checked_absolute_path, json_bytes, publish_exclusive
from d_audio_mrt2_contract import (
    CHANNELS,
    FIXED_MANIFEST,
    MODEL_REPOSITORY,
    PROFILE,
    SAMPLE_RATE,
    SDK_REVISION,
    ManifestSpec,
    MRT2Request,
    canonical_condition_bytes,
    condition_frames,
    encode_float32_wave,
    load_mrt2_json,
    validate_float32_wave,
    validate_launch_paths,
    validate_manifest,
    validate_request,
    verify_manifest_weights,
    MAX_MANIFEST_BYTES,
    MAX_REQUEST_BYTES,
)
from d_mrt2_export import ExportedMRT2


class OutputDeliveryError(Exception):
    """The JSONL control stream could not accept an event."""


class EngineFailure(Exception):
    """The engine lifecycle or generated PCM violated its contract."""


def _neutralize_descriptor(descriptor: int) -> None:
    replacement: int | None = None
    try:
        replacement = os.open(os.devnull, os.O_WRONLY | getattr(os, "O_CLOEXEC", 0))
        os.dup2(replacement, descriptor)
    except OSError:
        return
    finally:
        if replacement is not None:
            try:
                os.close(replacement)
            except OSError:
                pass


class EventWriter:
    def __init__(self) -> None:
        self.broken = False
        self.terminal = False

    def emit(self, value: dict[str, Any], *, terminal: bool = False) -> None:
        if self.broken:
            raise OutputDeliveryError("stdout is unavailable")
        if terminal and self.terminal:
            raise OutputDeliveryError("terminal event already emitted")
        try:
            text = json.dumps(
                value, ensure_ascii=False, separators=(",", ":"), allow_nan=False
            )
            sys.stdout.write(text + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, OSError, UnicodeError, TypeError, ValueError) as exc:
            self.broken = True
            _neutralize_descriptor(1)
            raise OutputDeliveryError(f"stdout delivery failed: {exc}") from exc
        if terminal:
            self.terminal = True

    def progress(self, run_id: str, phase: str, completed: int, total: int) -> None:
        self.emit(
            {
                "schemaVersion": 1,
                "type": "progress",
                "runID": run_id,
                "phase": phase,
                "completed": completed,
                "total": total,
            }
        )


class _DeferredTerminalWriter:
    """Delay the sole terminal event until security-scoped access is released."""

    def __init__(self, writer: EventWriter) -> None:
        self.writer = writer
        self.pending: dict[str, Any] | None = None

    def emit(self, value: dict[str, Any], *, terminal: bool = False) -> None:
        if not terminal:
            self.writer.emit(value)
            return
        if self.pending is not None:
            raise OutputDeliveryError("terminal event already deferred")
        self.pending = value

    def progress(self, run_id: str, phase: str, completed: int, total: int) -> None:
        self.writer.progress(run_id, phase, completed, total)

    def deliver(self) -> None:
        if self.pending is None:
            raise OutputDeliveryError("terminal event was not produced")
        self.writer.emit(self.pending, terminal=True)


def _diagnostic(message: str) -> None:
    try:
        sys.stderr.write(message + "\n")
        sys.stderr.flush()
    except (BrokenPipeError, OSError, UnicodeError):
        _neutralize_descriptor(2)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="d_audio_mrt2_backend.py", exit_on_error=False)
    parser.add_argument("--request", required=True)
    parser.add_argument("--job-directory", required=True)
    parser.add_argument("--model-directory", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--vendor-directory", required=True)
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--access-manifest")
    parser.add_argument("--access-run-id")
    return parser


def _error_event(run_id: str | None, kind: str, message: str) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "type": "error",
        "runID": run_id,
        "kind": kind,
        "message": message or "unknown error",
    }


def _check_cancel(cancelled: Callable[[], bool], message: str) -> None:
    if cancelled():
        raise InterruptedError(message)


def _mx_value(mx: Any, name: str) -> int | None:
    getter = getattr(mx, name, None)
    if getter is None:
        return None
    try:
        value = getter()
    except Exception:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _process_peak_rss_bytes() -> int | None:
    try:
        value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return None
        return value if sys.platform == "darwin" else value * 1024
    except (OSError, ValueError):
        return None


def _measure_allocations(phase: str) -> dict[str, Any]:
    mx = sys.modules.get("mlx.core")
    active = _mx_value(mx, "get_active_memory") if mx is not None else None
    cache = _mx_value(mx, "get_cache_memory") if mx is not None else None
    peak = _mx_value(mx, "get_peak_memory") if mx is not None else None
    if peak is not None and active is not None and peak < active:
        peak = None
    available = sum(value is not None for value in (active, cache, peak))
    return {
        "measurementKind": (
            "mlx-allocator"
            if available == 3
            else "partial-mlx-allocator"
            if available
            else "unavailable"
        ),
        "measurementPhase": phase,
        "activeBytes": active,
        "cacheBytes": cache,
        "peakBytes": peak,
        "processPeakRSSBytes": _process_peak_rss_bytes(),
    }


_PRIVATE_IDENTITY_KEYS = {"model_root", "graph_path", "state_path", "resource_paths"}


def _sanitize_identity(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: _sanitize_identity(child)
            for key, child in value.items()
            if key not in _PRIVATE_IDENTITY_KEYS
        }
    if isinstance(value, list):
        return [_sanitize_identity(child) for child in value]
    if isinstance(value, tuple):
        return [_sanitize_identity(child) for child in value]
    return value


def _engine_identity(engine: Any) -> dict[str, Any]:
    identity_method = getattr(engine, "identity", None)
    if not callable(identity_method):
        raise EngineFailure("MRT2 engine does not expose identity()")
    raw = identity_method()
    if not isinstance(raw, dict):
        raise EngineFailure("MRT2 engine identity must be an object")
    if (
        raw.get("profile") != PROFILE
        or raw.get("model_revision") != FIXED_MANIFEST.revision
        or raw.get("sdk_revision") != SDK_REVISION
    ):
        raise EngineFailure("MRT2 engine identity does not match the fixed profile")
    return _sanitize_identity(raw)


def _append_frame(samples: array, frame: Any) -> None:
    try:
        rows = frame.tolist() if hasattr(frame, "tolist") else list(frame)
    except (TypeError, ValueError) as exc:
        raise EngineFailure("MRT2 frame must be an iterable of stereo samples") from exc
    if len(rows) != 1_920:
        raise EngineFailure("MRT2 frame must contain exactly 1920 stereo samples")
    for row in rows:
        try:
            pair = list(row)
        except TypeError as exc:
            raise EngineFailure("MRT2 frame rows must contain two samples") from exc
        if len(pair) != CHANNELS:
            raise EngineFailure("MRT2 frame rows must contain two samples")
        for value in pair:
            if isinstance(value, bool):
                raise EngineFailure("MRT2 frame contains a non-finite sample")
            try:
                number = float(value)
            except (TypeError, ValueError, OverflowError) as exc:
                raise EngineFailure("MRT2 frame contains a non-numeric sample") from exc
            if not (float("-inf") < number < float("inf")):
                raise EngineFailure("MRT2 frame contains a non-finite sample")
            samples.append(number)


def _close_engine(engine: Any) -> dict[str, Any]:
    close = getattr(engine, "close", None)
    if not callable(close):
        raise EngineFailure("MRT2 engine does not expose close()")
    try:
        result = close()
    except BaseException as exc:
        raise EngineFailure(f"MRT2 engine close failed: {exc}") from exc
    if not isinstance(result, dict) or result.get("released") is not True:
        raise EngineFailure("MRT2 engine close did not release its runtime")
    return dict(result)


def _generate(
    request: MRT2Request,
    model: Path,
    writer: Any,
    engine_factory: Callable[[Path, str, int], Any],
    cancelled: Callable[[], bool],
) -> tuple[array, dict[str, float], dict[str, Any], dict[str, Any], dict[str, Any]]:
    engine: Any = None
    samples = array("f")
    timings: dict[str, float] = {}
    engine_identity: dict[str, Any] | None = None
    allocations = _measure_allocations("beforeConstruction")
    cleanup: dict[str, Any] | None = None
    primary_error: BaseException | None = None
    cleanup_progress_error: BaseException | None = None
    started = time.monotonic()
    try:
        writer.progress(request.run_id, "encodingText", 0, 1)
        _check_cancel(cancelled, "cancelled before MRT2 construction")
        engine = engine_factory(model, request.prompt, request.seed)
        _check_cancel(cancelled, "cancelled after MRT2 construction")
        writer.progress(request.run_id, "encodingText", 1, 1)

        total = request.sequence.duration_frames
        writer.progress(request.run_id, "denoising", 0, total)
        first_pcm: float | None = None
        for index, condition in enumerate(condition_frames(request.sequence)):
            _check_cancel(cancelled, "cancelled before MRT2 condition frame")
            frame = engine.generate_frame(condition)
            if first_pcm is None:
                first_pcm = time.monotonic() - started
            _append_frame(samples, frame)
            _check_cancel(cancelled, "cancelled after MRT2 condition frame")
            writer.progress(request.run_id, "denoising", index + 1, total)
        if first_pcm is None:
            raise EngineFailure("MRT2 engine returned no PCM frames")
        timings["firstPCM"] = first_pcm
        writer.progress(request.run_id, "decoding", 0, 1)
        if len(samples) != request.frame_count * CHANNELS:
            raise EngineFailure("MRT2 total PCM sample count mismatch")
        writer.progress(request.run_id, "decoding", 1, 1)
        engine_identity = _engine_identity(engine)
        allocations = _measure_allocations("afterGeneration")
    except BaseException as exc:
        primary_error = exc

    if engine is not None:
        try:
            writer.progress(request.run_id, "cleanup", 0, 1)
        except BaseException as exc:
            cleanup_progress_error = exc
        try:
            cleanup = _close_engine(engine)
        except BaseException as exc:
            primary_error = exc
        allocations["postCleanup"] = _measure_allocations("afterCleanup")
        try:
            writer.progress(request.run_id, "cleanup", 1, 1)
        except BaseException as exc:
            if cleanup_progress_error is None:
                cleanup_progress_error = exc

    timings["total"] = time.monotonic() - started
    if primary_error is not None:
        raise primary_error
    if cleanup_progress_error is not None:
        raise cleanup_progress_error
    if engine_identity is None or cleanup is None:
        raise EngineFailure("MRT2 engine lifecycle did not complete")
    return samples, timings, allocations, cleanup, engine_identity


def _metadata(
    request: MRT2Request,
    manifest: ManifestSpec,
    timings: dict[str, float],
    allocations: dict[str, Any],
    cleanup: dict[str, Any],
    engine_identity: dict[str, Any],
) -> dict[str, Any]:
    condition = request.condition_metadata()
    condition_digest = hashlib.sha256(canonical_condition_bytes(request)).hexdigest()
    return {
        "request": request.snapshot,
        "profile": PROFILE,
        "modelRepository": MODEL_REPOSITORY,
        "modelRevision": manifest.revision,
        "weightManifest": manifest.provenance(),
        "sdkRevision": SDK_REVISION,
        "condition": condition,
        "conditionSHA256": condition_digest,
        "engineIdentity": engine_identity,
        "timingsSeconds": timings,
        "mlxAllocations": allocations,
        "cleanup": cleanup,
    }


def _run(
    arguments: argparse.Namespace,
    request_path: Path,
    job: Path,
    model: Path,
    manifest_path: Path,
    vendor: Path,
    writer: Any,
    engine_factory: Callable[[Path, str, int], Any],
    cancelled: Callable[[], bool],
    manifest_spec: ManifestSpec,
    *,
    access_run_id: uuid.UUID | None = None,
) -> int:
    run_id: str | None = None
    try:
        validate_launch_paths(request_path, job, model, manifest_path, vendor)
        request_value = load_mrt2_json(
            request_path, label="request", max_bytes=MAX_REQUEST_BYTES
        )
        request = validate_request(request_value)
        run_id = request.run_id
        if access_run_id is not None and uuid.UUID(run_id) != access_run_id:
            raise ContractError("access run ID does not match request runID", "configuration")
        writer.progress(run_id, "validating", 0, 1)
        manifest_value = load_mrt2_json(
            manifest_path, label="manifest", max_bytes=MAX_MANIFEST_BYTES
        )
        try:
            manifest = validate_manifest(manifest_value, expected=manifest_spec)
        except ContractError as exc:
            raise ContractError(str(exc), "configuration") from exc
        _check_cancel(cancelled, "cancelled during validation")
        try:
            verify_manifest_weights(manifest, model, cancelled=cancelled)
        except InterruptedError:
            raise
        except ContractError as exc:
            raise ContractError(str(exc), "configuration") from exc
        writer.progress(run_id, "validating", 1, 1)
        if arguments.inspect:
            writer.emit(
                {
                    "schemaVersion": 1,
                    "type": "inspection",
                    "runID": run_id,
                    "profile": PROFILE,
                    "modelRepository": manifest.repository,
                    "modelRevision": manifest.revision,
                    "requiredWeightBytes": manifest.required_weight_bytes,
                    "weightManifest": manifest.provenance(),
                },
                terminal=True,
            )
            return 0

        samples, timings, allocations, cleanup, engine_identity = _generate(
            request, model, writer, engine_factory, cancelled
        )
        _check_cancel(cancelled, "cancelled after MRT2 cleanup")
        writer.progress(run_id, "publishing", 0, 2)
        publishing_started = time.monotonic()
        wav_bytes = encode_float32_wave(samples, request.frame_count)
        wav_digest = validate_float32_wave(wav_bytes, expected_frames=request.frame_count)
        output_path = publish_exclusive(
            job,
            "output.wav",
            wav_bytes,
            validate=lambda content: validate_float32_wave(
                content, expected_frames=request.frame_count
            ),
        )
        writer.progress(run_id, "publishing", 1, 2)
        timings["publishing"] = time.monotonic() - publishing_started
        result = {
            "schemaVersion": 1,
            "type": "result",
            "runID": run_id,
            "artifact": {
                "path": str(output_path),
                "sha256": wav_digest,
                "byteCount": len(wav_bytes),
                "frameCount": request.frame_count,
                "sampleRate": SAMPLE_RATE,
                "channels": CHANNELS,
                "encoding": "float32",
            },
            "metadata": _metadata(
                request, manifest, timings, allocations, cleanup, engine_identity
            ),
        }
        result_filename = (
            "pending-result.json" if access_run_id is not None else "result.json"
        )
        publish_exclusive(job, result_filename, json_bytes(result))
        writer.progress(run_id, "publishing", 2, 2)
        writer.emit(result, terminal=True)
        return 0
    except OutputDeliveryError as exc:
        _diagnostic(str(exc))
        return 2
    except InterruptedError as exc:
        try:
            writer.emit(_error_event(run_id, "cancelled", str(exc)), terminal=True)
        except OutputDeliveryError as output_exc:
            _diagnostic(str(output_exc))
        return 130
    except ContractError as exc:
        try:
            writer.emit(_error_event(run_id, exc.kind, str(exc)), terminal=True)
        except OutputDeliveryError as output_exc:
            _diagnostic(str(output_exc))
        return 2
    except BaseException as exc:
        _diagnostic(f"engine diagnostic: {exc}")
        try:
            writer.emit(_error_event(run_id, "engine", str(exc)), terminal=True)
        except OutputDeliveryError as output_exc:
            _diagnostic(str(output_exc))
        return 1


def _paths_overlap(first: Path, second: Path) -> bool:
    return first == second or first in second.parents or second in first.parents


def _access_arguments(
    arguments: argparse.Namespace, request_path: Path, job: Path, model: Path
) -> tuple[Path, uuid.UUID, tuple[Path, ...]] | None:
    manifest_raw = arguments.access_manifest
    run_id_raw = arguments.access_run_id
    if manifest_raw is None and run_id_raw is None:
        return None
    if manifest_raw is None or run_id_raw is None:
        raise ContractError(
            "--access-manifest and --access-run-id must be supplied together",
            "configuration",
        )
    try:
        parsed_run_id = uuid.UUID(run_id_raw)
    except (ValueError, AttributeError, TypeError) as exc:
        raise ContractError("--access-run-id must be a UUID", "configuration") from exc
    access_manifest = checked_absolute_path(manifest_raw, label="--access-manifest")
    run_directory = request_path.parent
    if job.name != "job" or job.parent != run_directory:
        raise ContractError(
            "access mode requires request and job to share a parent and job to be named 'job'",
            "configuration",
        )
    allowed = (model, run_directory)
    if any(path == Path(path.anchor) for path in allowed):
        raise ContractError("access grants must not name a filesystem root", "configuration")
    if _paths_overlap(*allowed):
        raise ContractError("model and run access directories must be separate", "configuration")
    if any(path == access_manifest or path in access_manifest.parents for path in allowed):
        raise ContractError(
            "access manifest must remain outside granted model/run directories",
            "configuration",
        )
    return access_manifest, parsed_run_id, allowed


def _emit_configuration_error(writer: EventWriter, message: str) -> int:
    try:
        writer.emit(_error_event(None, "configuration", message), terminal=True)
    except OutputDeliveryError as output_exc:
        _diagnostic(str(output_exc))
    return 2


def _execute(
    argv: Sequence[str] | None,
    writer: EventWriter,
    engine_factory: Callable[[Path, str, int], Any],
    cancelled: Callable[[], bool],
    manifest_spec: ManifestSpec,
) -> int:
    try:
        try:
            arguments = _parser().parse_args(argv)
        except (argparse.ArgumentError, SystemExit) as exc:
            raise ContractError(f"invalid CLI arguments: {exc}", "configuration") from exc
        request_path = checked_absolute_path(arguments.request, label="--request")
        job = checked_absolute_path(arguments.job_directory, label="--job-directory")
        model = checked_absolute_path(arguments.model_directory, label="--model-directory")
        manifest_path = checked_absolute_path(arguments.manifest, label="--manifest")
        vendor = checked_absolute_path(arguments.vendor_directory, label="--vendor-directory")
        access = _access_arguments(arguments, request_path, job, model)
    except ContractError as exc:
        return _emit_configuration_error(writer, str(exc))

    if access is None:
        return _run(
            arguments,
            request_path,
            job,
            model,
            manifest_path,
            vendor,
            writer,
            engine_factory,
            cancelled,
            manifest_spec,
        )

    access_manifest, access_run_id, allowed = access
    deferred = _DeferredTerminalWriter(writer)
    try:
        with acquire_file_access(
            access_manifest, run_id=str(access_run_id), allowed_paths=allowed
        ):
            code = _run(
                arguments,
                request_path,
                job,
                model,
                manifest_path,
                vendor,
                deferred,
                engine_factory,
                cancelled,
                manifest_spec,
                access_run_id=access_run_id,
            )
    except AudioAccessError:
        return _emit_configuration_error(writer, "file access configuration failed")
    try:
        deferred.deliver()
    except OutputDeliveryError as exc:
        _diagnostic(str(exc))
        return 2
    return code


def main(
    argv: Sequence[str] | None = None,
    *,
    engine_factory: Callable[[Path, str, int], Any] = ExportedMRT2,
    manifest_spec: ManifestSpec = FIXED_MANIFEST,
) -> int:
    writer = EventWriter()
    cancellation = {"requested": False}

    def handle_signal(_signum: int, _frame: Any) -> None:
        cancellation["requested"] = True

    old_handlers: dict[int, Any] = {}
    for number in (signal.SIGINT, signal.SIGTERM):
        old_handlers[number] = signal.getsignal(number)
        signal.signal(number, handle_signal)
    try:
        return _execute(
            argv,
            writer,
            engine_factory,
            lambda: cancellation["requested"],
            manifest_spec,
        )
    finally:
        for number, old_handler in old_handlers.items():
            signal.signal(number, old_handler)


if __name__ == "__main__":
    raise SystemExit(main())
