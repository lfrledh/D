#!/usr/bin/env python3
"""Thin offline JSONL adapter to official AceStepHandler.generate_music."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import random
import signal
import sys
from typing import Any, Callable, Sequence

from d_audio_access import AudioAccessError, acquire_file_access
from d_audio_contract import ContractError, checked_absolute_path, publish_exclusive, validate_launch_paths
from d_audio_mrt2_contract import encode_float32_wave, validate_float32_wave
from d_audio_ace_contract import (
    ACEContractError, MAX_MANIFEST_BYTES, MAX_REQUEST_BYTES, MODEL_REVISION,
    PROFILE, SHARED_REVISION, SOURCE_REVISION, load_json, reference_path,
    validate_manifest, validate_request, verify_manifest_files, verify_source_files, verify_wav,
)
from d_ace_offline_runtime import (forbid_torch_fallback, make_handler,
                                   local_only_loading, prepare_runtime_view,
                                   verify_runtime_view)


class DeliveryError(Exception):
    pass


class EventWriter:
    def __init__(self) -> None:
        self.terminal = False

    def emit(self, value: dict[str, Any], *, terminal: bool = False) -> None:
        if self.terminal:
            raise DeliveryError("ACE terminal event already emitted")
        try:
            sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n")
            sys.stdout.flush()
        except (OSError, UnicodeError, TypeError, ValueError) as exc:
            raise DeliveryError(f"ACE control stream failed: {exc}") from exc
        if terminal:
            self.terminal = True

    def progress(self, run_id: str, phase: str, completed: int, total: int) -> None:
        self.emit({"schemaVersion": 1, "type": "progress", "runID": run_id,
                   "phase": phase, "completed": completed, "total": total})


class DeferredWriter:
    def __init__(self, writer: EventWriter) -> None:
        self.writer = writer
        self.pending: dict[str, Any] | None = None

    def emit(self, value: dict[str, Any], *, terminal: bool = False) -> None:
        if terminal:
            if self.pending is not None:
                raise DeliveryError("ACE terminal event already deferred")
            self.pending = value
        else:
            self.writer.emit(value)

    def progress(self, run_id: str, phase: str, completed: int, total: int) -> None:
        self.writer.progress(run_id, phase, completed, total)

    def deliver(self) -> None:
        if self.pending is None:
            raise DeliveryError("ACE terminal event missing")
        self.writer.emit(self.pending, terminal=True)


def _error(run_id: str | None, kind: str, message: str) -> dict[str, Any]:
    return {"schemaVersion": 1, "type": "error", "runID": run_id,
            "kind": kind, "message": message or "ACE provider failed"}


def _snapshot(paths: list[Path]) -> dict[Path, tuple[int, int, int, int, int]]:
    result = {}
    for path in paths:
        stat = path.lstat()
        result[path] = (stat.st_dev, stat.st_ino, stat.st_size,
                        stat.st_mtime_ns, stat.st_ctime_ns)
    return result


def build_generate_kwargs(request: dict[str, Any], handler: Any) -> tuple[dict[str, Any], str]:
    """Map every registered condition to actual official handler fields."""
    ace = request["parameters"]["ace"]
    vocal = ace["vocal"]
    lyrics = "[Instrumental]" if vocal["kind"] == "instrumental" else vocal["text"]
    language = "en" if vocal["kind"] == "instrumental" else vocal["language"]
    operation = request["operation"]
    task = {"generate": "text2music", "variation": "cover", "inpaint": "repaint"}[operation]
    options = ace.get("editOptions") or {}
    region = request.get("editRegion")
    kwargs = {
        "captions": request["prompt"], "lyrics": lyrics, "vocal_language": language,
        "bpm": ace.get("bpm"), "key_scale": ace.get("keyScale") or "",
        "time_signature": ace.get("timeSignature") or "",
        "inference_steps": ace["steps"], "guidance_scale": ace["guidanceScale"],
        "seed": request["seed"], "use_random_seed": False, "batch_size": 1,
        "audio_duration": request["durationSeconds"],
        "reference_audio": (str(reference_path(ace["referenceAudio"]))
                            if ace.get("referenceAudio") else None),
        "src_audio": (str(reference_path(request["source"]))
                      if request.get("source") else None),
        "task_type": task, "instruction": handler.generate_instruction(task),
        "audio_code_string": "", "source_repaint_latents": None,
        "dcw_enabled": False, "flow_edit_morph": False,
        "audio_cover_strength": options.get("audioCoverStrength", 1.0),
        "cover_noise_strength": options.get("noiseStrength", 0.0),
        "repaint_mode": "balanced", "repaint_strength": options.get("strength", 0.5),
        "repainting_start": region["startFrame"] / 48000.0 if region else 0.0,
        "repainting_end": region["endFrame"] / 48000.0 if region else None,
    }
    return kwargs, lyrics


def precheck_tokens(handler: Any, kwargs: dict[str, Any]) -> dict[str, int]:
    """Measure the actual official SFT templates with truncation disabled."""
    from acestep.constants import SFT_GEN_PROMPT

    caption = handler.extract_caption_from_sft_format(kwargs["captions"])
    meta = handler._build_metadata_dict(kwargs["bpm"], kwargs["key_scale"],
                                        kwargs["time_signature"], kwargs["audio_duration"])
    meta_text = handler._dict_to_meta_string(meta)
    instruction = handler._format_instruction(kwargs["instruction"])
    text = SFT_GEN_PROMPT.format(instruction, caption, meta_text)
    lyric_text = handler._format_lyrics(kwargs["lyrics"], kwargs["vocal_language"])
    counts: dict[str, int] = {}
    for label, value, limit in (("caption", text, 256), ("lyrics", lyric_text, 2048)):
        tokens = handler.text_tokenizer(value, padding=False, truncation=False)
        ids = tokens.input_ids if hasattr(tokens, "input_ids") else tokens["input_ids"]
        if ids and isinstance(ids[0], list):
            ids = ids[0]
        if not isinstance(ids, (list, tuple)) or len(ids) > limit:
            raise ACEContractError(f"ACE {label} template exceeds {limit} tokens; no truncation")
        counts[label] = len(ids)
    return counts


def float32_samples(payload: dict[str, Any]) -> tuple[Any, int]:
    if payload.get("success") is not True or payload.get("error"):
        raise ACEContractError(str(payload.get("error") or "official ACE generation failed"), "engine")
    audios = payload.get("audios")
    if not isinstance(audios, list) or len(audios) != 1:
        raise ACEContractError("official ACE did not return exactly one audio", "engine")
    item = audios[0]
    if not isinstance(item, dict) or item.get("sample_rate") != 48000:
        raise ACEContractError("official ACE output sample rate changed", "output")
    import numpy as np

    tensor = item.get("tensor")
    if tensor is None or not hasattr(tensor, "detach"):
        raise ACEContractError("official ACE output tensor is absent", "output")
    values = np.asarray(tensor.detach().cpu(), dtype=np.float32)
    if values.ndim == 3 and values.shape[0] == 1:
        values = values[0]
    if values.ndim != 2 or values.shape[0] != 2 or values.shape[1] <= 0:
        raise ACEContractError("official ACE output must be nonempty stereo", "output")
    if not np.isfinite(values).all():
        raise ACEContractError("official ACE output has nonfinite PCM", "output")
    return values.T.reshape(-1), int(values.shape[1])


def run_provider(request_path: Path, job: Path, model: Path, manifest_path: Path,
                 vendor: Path, writer: Any, cancelled: Callable[[], bool],
                 handler_factory: Callable[[Path, dict[str, Any], Path, Path], Any],
                 *, access_mode: bool = False) -> int:
    run_id: str | None = None
    manifest: dict[str, Any] | None = None
    request: dict[str, Any] | None = None
    view: Path | None = None
    admitted: dict[Path, tuple[int, int, int, int, int]] = {}
    delivery = DeferredWriter(writer)
    writer = delivery
    try:
        if "ACESTEP_CHECKPOINTS_DIR" in os.environ:
            raise ACEContractError("ACESTEP_CHECKPOINTS_DIR overrides the private ACE view", "configuration")
        validate_launch_paths(request_path, job, model, manifest_path, vendor)
        request = validate_request(load_json(request_path, MAX_REQUEST_BYTES))
        run_id = request["runID"]
        writer.progress(run_id, "validating", 0, 1)
        manifest = validate_manifest(load_json(manifest_path, MAX_MANIFEST_BYTES))
        if cancelled():
            raise InterruptedError("cancelled before ACE validation")
        verify_manifest_files(manifest, model)
        verify_source_files(manifest, vendor)
        admitted = _snapshot([model / item["path"] for item in manifest["files"]]
                             + [vendor / item["path"] for item in manifest["sourceFiles"]])
        for ref in (request.get("source"), request["parameters"]["ace"].get("referenceAudio")):
            if ref is not None:
                verify_wav(ref)
        writer.progress(run_id, "validating", 1, 1)
        if cancelled():
            raise InterruptedError("cancelled before ACE initialization")
        view = prepare_runtime_view(request_path.parent, model, vendor, manifest)
        admitted.update(_snapshot([path for path in view.rglob("*")
                                   if path.is_file() or path.is_symlink()]))
        handler = handler_factory(vendor, manifest, view, model)
        try:
            with local_only_loading(view):
                status, ready = handler.initialize_service(
                    project_root=str(view), config_path="acestep-v15-xl-sft", device="mps",
                    use_flash_attention=False, compile_model=False,
                    offload_to_cpu=True, offload_dit_to_cpu=True,
                    quantization=None, prefer_source=None, use_mlx_dit=True,
                    vae_checkpoint="official")
            if ready is not True:
                raise ACEContractError(f"official ACE initialization failed: {status}", "configuration")
            if getattr(handler, "dtype", None) is None or str(handler.dtype) != "torch.float32":
                raise ACEContractError("ACE XL SFT runtime precision is not float32", "configuration")
            forbid_torch_fallback(handler)
            kwargs, effective_lyrics = build_generate_kwargs(request, handler)
            writer.progress(run_id, "encodingText", 0, 1)
            counts = precheck_tokens(handler, kwargs)
            writer.progress(run_id, "encodingText", 1, 1)
            if cancelled():
                raise InterruptedError("cancelled before ACE generation")
            random.seed(request["seed"])
            writer.progress(run_id, "denoising", 0, 1)
            payload = handler.generate_music(**kwargs)
            writer.progress(run_id, "denoising", 1, 1)
            if cancelled():
                raise InterruptedError("cancelled after ACE generation")
            writer.progress(run_id, "decoding", 0, 1)
            samples, frames = float32_samples(payload)
            requested_frames = round(request["durationSeconds"] * 48000)
            if frames > max(requested_frames, 245_760) + 96_000:
                raise ACEContractError("official ACE output exceeds bounded decode envelope", "output")
            wav = encode_float32_wave(samples, frames)
            digest = validate_float32_wave(wav, expected_frames=frames)
            writer.progress(run_id, "decoding", 1, 1)
        finally:
            # The child is one job per process. Release references before reporting success.
            del handler
        if cancelled():
            raise InterruptedError("cancelled before ACE publication")
        writer.progress(run_id, "publishing", 0, 2)
        output = publish_exclusive(job, "output.wav", wav,
                                   validate=lambda raw: validate_float32_wave(raw, expected_frames=frames))
        writer.progress(run_id, "publishing", 1, 2)
        metadata = {
            "request": request, "profile": PROFILE, "modelRevision": MODEL_REVISION,
            "sharedRevision": SHARED_REVISION, "sourceRevision": SOURCE_REVISION,
            "precision": "XL=float32,MLX=float32,output=float32", "device": "mps+mlx",
            "requestedFrames": requested_frames, "effectiveFrames": requested_frames,
            "deliveredFrames": frames, "tailPaddingFrames": max(0, frames - requested_frames),
            "shortfallFrames": max(0, requested_frames - frames),
            "effectiveLyrics": effective_lyrics,
            "captionTokens": counts["caption"], "lyricTokens": counts["lyrics"],
            "taskType": kwargs["task_type"],
            "sourceSHA256": request.get("source", {}).get("sha256") if request.get("source") else None,
            "referenceSHA256": (request["parameters"]["ace"].get("referenceAudio") or {}).get("sha256"),
            "weightManifest": manifest["files"], "sourceManifest": manifest["sourceFiles"],
            "offloadToCPU": True,
            "offloadDiTToCPU": True,
        }
        result = {"schemaVersion": 1, "type": "result", "runID": run_id,
                  "artifact": {"path": str(output), "sha256": digest,
                               "byteCount": len(wav), "frameCount": frames,
                               "sampleRate": 48000, "channels": 2, "encoding": "float32"},
                  "metadata": metadata}
        name = "pending-result.json" if access_mode else "result.json"
        publish_exclusive(job, name, json.dumps(result, ensure_ascii=False,
            separators=(",", ":"), allow_nan=False).encode("utf-8"))
        writer.progress(run_id, "publishing", 2, 2)
        writer.emit(result, terminal=True)
        return 0
    except DeliveryError:
        return 2
    except InterruptedError as exc:
        try: writer.emit(_error(run_id, "cancelled", str(exc)), terminal=True)
        except DeliveryError: pass
        return 130
    except (ACEContractError, ContractError) as exc:
        try: writer.emit(_error(run_id, exc.kind, str(exc)), terminal=True)
        except DeliveryError: pass
        return 2
    except BaseException as exc:
        try: sys.stderr.write(f"ACE engine diagnostic: {type(exc).__name__}: {exc}\n")
        except OSError: pass
        try: writer.emit(_error(run_id, "engine", str(exc)), terminal=True)
        except DeliveryError: pass
        return 1
    finally:
        failures: list[str] = []
        if manifest is not None:
            try:
                verify_manifest_files(manifest, model)
                verify_source_files(manifest, vendor)
                if view is not None:
                    verify_runtime_view(view, model, vendor, manifest)
                if admitted and _snapshot(list(admitted)) != admitted:
                    raise ACEContractError("ACE admitted file identity changed", "configuration")
            except (ACEContractError, OSError) as exc:
                failures.append(str(exc))
        if request is not None:
            for ref in (request.get("source"), request["parameters"]["ace"].get("referenceAudio")):
                if ref is not None:
                    try: verify_wav(ref)
                    except (ACEContractError, OSError) as exc: failures.append(str(exc))
        if failures:
            delivery.pending = _error(run_id, "inputMutation", "; ".join(failures))
        try:
            delivery.deliver()
        except DeliveryError:
            pass
        if failures:
            return 2


def parser() -> argparse.ArgumentParser:
    item = argparse.ArgumentParser(prog="d_audio_ace_backend.py", exit_on_error=False)
    for option in ("request", "job-directory", "model-directory", "manifest", "vendor-directory"):
        item.add_argument("--" + option, required=True)
    item.add_argument("--access-manifest")
    item.add_argument("--access-run-id")
    return item


def main(argv: Sequence[str] | None = None,
         *, handler_factory: Callable[[Path, dict[str, Any], Path, Path], Any] = make_handler) -> int:
    writer = EventWriter()
    requested = {"cancelled": False}

    def stop(_signum: int, _frame: Any) -> None:
        requested["cancelled"] = True

    previous = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
    for number in previous: signal.signal(number, stop)
    try:
        args = parser().parse_args(argv)
        request = checked_absolute_path(args.request, label="ACE request")
        job = checked_absolute_path(args.job_directory, label="ACE job")
        model = checked_absolute_path(args.model_directory, label="ACE model")
        manifest = checked_absolute_path(args.manifest, label="ACE manifest")
        vendor = checked_absolute_path(args.vendor_directory, label="ACE official source")
        access_mode = args.access_manifest is not None or args.access_run_id is not None
        if access_mode:
            if args.access_manifest is None or args.access_run_id is None:
                raise ACEContractError("ACE access manifest and run ID must be paired", "configuration")
            from uuid import UUID
            access_manifest = checked_absolute_path(args.access_manifest, label="ACE access manifest")
            access_id = str(UUID(args.access_run_id))
            deferred = DeferredWriter(writer)
            with acquire_file_access(access_manifest, run_id=access_id,
                                     allowed_paths=(model, vendor, request.parent)):
                code = run_provider(request, job, model, manifest, vendor, deferred,
                                    lambda: requested["cancelled"], handler_factory,
                                    access_mode=True)
            deferred.deliver()
            return code
        return run_provider(request, job, model, manifest, vendor, writer,
                            lambda: requested["cancelled"], handler_factory)
    except (ACEContractError, ContractError, AudioAccessError, ValueError, argparse.ArgumentError) as exc:
        try: writer.emit(_error(None, "configuration", str(exc)), terminal=True)
        except DeliveryError: pass
        return 2
    finally:
        for number, old in previous.items(): signal.signal(number, old)


if __name__ == "__main__":
    raise SystemExit(main())
