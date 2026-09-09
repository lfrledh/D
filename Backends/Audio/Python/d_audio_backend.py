#!/usr/bin/env python3
"""AUDIO1 JSON-lines CLI for the pinned local SA3 provider."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import time
from typing import Any, Callable, Sequence

from d_audio_contract import (
    CHANNELS,
    MODEL_REPOSITORY,
    SAMPLE_RATE,
    AudioRequest,
    ContractError,
    WaveData,
    checked_absolute_path,
    encode_float32_wave,
    estimate_peak_bytes,
    json_bytes,
    load_strict_json,
    preserve_inpaint_outside,
    publish_exclusive,
    read_source_wave,
    validate_float32_output,
    validate_launch_paths,
    validate_manifest,
    validate_request,
    validate_source_relationships,
    verify_manifest_weights,
)
from d_audio_sa3 import CancelledError, InferenceResult, run_inference, verify_vendor


class OutputDeliveryError(Exception):
    pass


def _neutralize_descriptor(descriptor: int) -> None:
    """Make interpreter shutdown flushing harmless after a stream write fails."""
    replacement = None
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
            text = json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            sys.stdout.write(text + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, OSError, UnicodeError, ValueError) as exc:
            self.broken = True
            _neutralize_descriptor(1)
            raise OutputDeliveryError(f"stdout delivery failed: {exc}") from exc
        if terminal:
            self.terminal = True

    def progress(self, run_id: str, phase: str, completed: int, total: int) -> None:
        self.emit({"schemaVersion": 1, "type": "progress", "runID": run_id,
                   "phase": phase, "completed": completed, "total": total})


def _diagnostic(message: str) -> None:
    try:
        sys.stderr.write(message + "\n")
        sys.stderr.flush()
    except (BrokenPipeError, OSError, UnicodeError):
        _neutralize_descriptor(2)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="d_audio_backend.py", exit_on_error=False)
    parser.add_argument("--request", required=True)
    parser.add_argument("--job-directory", required=True)
    parser.add_argument("--model-directory", required=True)
    parser.add_argument("--profile", required=True, choices=("sm-music", "sm-sfx", "medium"))
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--vendor-directory", required=True)
    parser.add_argument("--inspect", action="store_true")
    return parser


def _error_event(run_id: str | None, kind: str, message: str) -> dict[str, Any]:
    return {"schemaVersion": 1, "type": "error", "runID": run_id,
            "kind": kind, "message": message or "unknown error"}


def _source_conversion(encoding: str) -> str:
    if encoding == "int32":
        return "signed-int32-to-IEEE-float32-rounded"
    if encoding in ("int16", "int24"):
        return f"signed-{encoding}-to-IEEE-float32-exact"
    return "IEEE-float32-preserved"


def _metadata(
    request: AudioRequest,
    profile: str,
    manifest: Any,
    source: WaveData | None,
    inference: InferenceResult,
) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "request": request.snapshot,
        "profile": profile,
        "modelRepository": MODEL_REPOSITORY,
        "modelRevision": manifest.revision,
        "weightManifest": manifest.provenance(),
        "vendorRevision": "779434a908193105335fd8d833418603625b2859",
        "precision": {"dit": "float16", "text": "float16", "encoder": "float32",
                      "decoder": "float32", "master": "float32"},
        "timingsSeconds": inference.timings_seconds,
        "mlxAllocations": inference.mlx_allocations,
    }
    if source is not None:
        metadata["sourceSampleEncoding"] = source.source_encoding
        metadata["sourceToMasterConversion"] = _source_conversion(source.source_encoding)
    if request.edit_region is not None and request.effective_latent_region is not None:
        metadata["requestedRegionFrames"] = {
            "startFrame": request.edit_region.start_frame,
            "endFrame": request.edit_region.end_frame,
        }
        metadata["effectiveLatentRegion"] = {
            "start": request.effective_latent_region[0],
            "end": request.effective_latent_region[1],
        }
        metadata["inpaintBoundaryPolicy"] = "no-crossfade; exact float32 source conversion outside requested frames"
    if request.operation == "variation":
        metadata["variationGuarantee"] = "approximate reference; no exact melody guarantee"
    return metadata


def _execute(
    argv: Sequence[str] | None,
    writer: EventWriter,
    engine: Callable[..., InferenceResult],
    cancelled: Callable[[], bool],
) -> int:
    run_id: str | None = None
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
        validate_launch_paths(request_path, job, model, manifest_path, vendor)
        request_value = load_strict_json(request_path, label="request")
        request = validate_request(request_value, profile=arguments.profile)
        run_id = request.run_id
        writer.progress(run_id, "validating", 0, 1)
        manifest_value = load_strict_json(manifest_path, label="manifest")
        try:
            manifest = validate_manifest(manifest_value, profile=arguments.profile)
        except ContractError as exc:
            raise ContractError(str(exc), "configuration") from exc
        source: WaveData | None = None
        if request.source is not None:
            validate_source_relationships(request.source, request_path, job, model, manifest_path, vendor)
            source = read_source_wave(request.source)
        if cancelled():
            raise CancelledError("cancelled during validation")
        verify_manifest_weights(manifest, model)
        verify_vendor(vendor)
        writer.progress(run_id, "validating", 1, 1)
        estimated = estimate_peak_bytes(manifest, request.duration_seconds)
        if arguments.inspect:
            writer.emit({
                "schemaVersion": 1,
                "type": "inspection",
                "runID": run_id,
                "profile": arguments.profile,
                "modelRevision": manifest.revision,
                "requiredWeightBytes": manifest.required_weight_bytes,
                "estimatedPeakBytes": estimated,
                "estimateKind": "conservative-unmeasured",
                "capabilities": {"generate": True, "variation": "approximate",
                                 "inpaint": "exact-outside-region-after-float32-conversion"},
            }, terminal=True)
            return 0

        if source is not None:
            publish_exclusive(job, "frozen-source.wav", source.raw_bytes)
        inference = engine(
            request, manifest, model, vendor, source,
            lambda phase, complete, total: writer.progress(run_id, phase, complete, total),
            cancelled,
        )
        writer.progress(run_id, "cleanup", 0, 1)
        writer.progress(run_id, "cleanup", 1, 1)
        if cancelled():
            raise CancelledError("cancelled after engine cleanup")
        writer.progress(run_id, "publishing", 0, 2)
        publishing_started = time.monotonic()
        samples = inference.samples
        if request.operation == "inpaint":
            assert source is not None and request.edit_region is not None
            samples = preserve_inpaint_outside(samples, source, request.edit_region)
        wav_bytes = encode_float32_wave(samples, request.requested_frames)
        wav_digest = validate_float32_output(wav_bytes, request.requested_frames)
        output_path = publish_exclusive(
            job, "output.wav", wav_bytes,
            validate=lambda content: validate_float32_output(content, request.requested_frames),
        )
        writer.progress(run_id, "publishing", 1, 2)
        inference.timings_seconds["publishing"] = time.monotonic() - publishing_started
        result = {
            "schemaVersion": 1,
            "type": "result",
            "runID": run_id,
            "artifact": {"path": str(output_path), "sha256": wav_digest,
                         "byteCount": len(wav_bytes), "frameCount": request.requested_frames,
                         "sampleRate": SAMPLE_RATE, "channels": CHANNELS, "encoding": "float32"},
            "metadata": _metadata(request, arguments.profile, manifest, source, inference),
        }
        publish_exclusive(job, "result.json", json_bytes(result))
        writer.progress(run_id, "publishing", 2, 2)
        writer.emit(result, terminal=True)
        return 0
    except OutputDeliveryError as exc:
        _diagnostic(str(exc))
        return 2
    except CancelledError as exc:
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
    except Exception as exc:
        _diagnostic(f"engine diagnostic: {exc}")
        try:
            writer.emit(_error_event(run_id, "engine", str(exc)), terminal=True)
        except OutputDeliveryError as output_exc:
            _diagnostic(str(output_exc))
        return 1


def main(argv: Sequence[str] | None = None, *, engine: Callable[..., InferenceResult] = run_inference) -> int:
    writer = EventWriter()
    cancellation = {"requested": False}

    def handle_signal(_signum: int, _frame: Any) -> None:
        cancellation["requested"] = True

    old_handlers: dict[int, Any] = {}
    for number in (signal.SIGINT, signal.SIGTERM):
        old_handlers[number] = signal.getsignal(number)
        signal.signal(number, handle_signal)
    try:
        return _execute(argv, writer, engine, lambda: cancellation["requested"])
    finally:
        for number, old in old_handlers.items():
            signal.signal(number, old)


if __name__ == "__main__":
    raise SystemExit(main())
