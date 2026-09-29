"""Offline argument planning for the pinned ltx-2-mlx one-stage dev CLI.

This module does not execute a process or certify that a model pack is complete,
BF16, non-quantized, or actually an LTX 2.3/2.5 pack. The execution admission
check must verify those properties and recheck paths immediately before launch.
"""

from __future__ import annotations

import math
import os
from pathlib import Path


_PROFILES = frozenset({"ltx-2.3-dev-bf16-full-v1", "ltx-2.5-dev-bf16-full-v1"})
_REQUEST_FIELDS = frozenset(
    {
        "schema_version",
        "profile",
        "prompt",
        "negative_prompt",
        "width",
        "height",
        "frames",
        "fps",
        "steps",
        "seed",
        "stream_weights",
        "cfg_scale",
        "stg_scale",
    }
)
_UPSTREAM_COMMIT = "1724ca673d59f023a8a95efee06e5d36d61c2765"


def _absolute_path(value: object, name: str) -> Path:
    if not isinstance(value, (str, os.PathLike)):
        raise ValueError(f"{name} must be an absolute local path")
    try:
        path = Path(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be an absolute local path") from exc
    if not path.is_absolute() or "\x00" in str(path):
        raise ValueError(f"{name} must be an absolute local path")
    return path


def _local_file(value: object, name: str, *, executable: bool = False) -> Path:
    path = _absolute_path(value, name)
    try:
        valid = path.is_file()
        runnable = not executable or os.access(path, os.X_OK)
    except (OSError, ValueError) as exc:
        raise ValueError(f"{name} must be an existing local file") from exc
    if not valid or not runnable:
        requirement = "executable local file" if executable else "local file"
        raise ValueError(f"{name} must be an existing {requirement}")
    return path


def _local_directory(value: object, name: str) -> Path:
    path = _absolute_path(value, name)
    try:
        valid = path.is_dir()
    except (OSError, ValueError) as exc:
        raise ValueError(f"{name} must be an existing local directory") from exc
    if not valid:
        raise ValueError(f"{name} must be an existing local directory")
    return path


def _unused_output(value: object) -> Path:
    path = _absolute_path(value, "output")
    try:
        # exists() misses dangling symlinks. lexists() catches them and any
        # other name that must not be overwritten by the eventual executor.
        occupied = os.path.lexists(path)
        parent_is_dir = path.parent.is_dir()
    except (OSError, ValueError) as exc:
        raise ValueError("output path cannot be checked") from exc
    if occupied:
        raise ValueError("output already exists")
    if not parent_is_dir:
        raise ValueError("output parent must be an existing local directory")
    return path


def _integer(value: object, name: str, *, minimum: int, maximum: int | None = None) -> int:
    if type(value) is not int or value < minimum or (maximum is not None and value > maximum):
        raise ValueError(f"{name} is out of range or is not an integer")
    return value


def _finite_number(value: object, name: str, *, positive: bool = False) -> int | float:
    if type(value) not in (int, float):
        raise ValueError(f"{name} must be a finite number")
    try:
        finite = math.isfinite(value)
    except (OverflowError, ValueError):
        finite = False
    if not finite or (positive and value <= 0):
        raise ValueError(f"{name} must be a finite{' positive' if positive else ''} number")
    return value


def _checked_request(request: object) -> dict:
    if type(request) is not dict:
        raise ValueError("request must be a dict")
    if set(request) != _REQUEST_FIELDS:
        missing = sorted(_REQUEST_FIELDS - set(request))
        unknown = sorted(set(request) - _REQUEST_FIELDS, key=str)
        raise ValueError(f"request fields differ from v1: missing={missing}, unknown={unknown}")
    if type(request["schema_version"]) is not int or request["schema_version"] != 1:
        raise ValueError("schema_version must be integer 1")
    if type(request["profile"]) is not str or request["profile"] not in _PROFILES:
        raise ValueError("unsupported LTX profile")
    if type(request["prompt"]) is not str or not request["prompt"] or "\x00" in request["prompt"]:
        raise ValueError("prompt must be a nonempty string without NUL")
    if type(request["negative_prompt"]) is not str or "\x00" in request["negative_prompt"]:
        raise ValueError("negative_prompt must be a string without NUL (empty is allowed)")
    width = _integer(request["width"], "width", minimum=1)
    height = _integer(request["height"], "height", minimum=1)
    if width % 32 or height % 32:
        raise ValueError("width and height must each be divisible by 32")
    frames = _integer(request["frames"], "frames", minimum=1)
    if (frames - 1) % 8:
        raise ValueError("frames must be 8n+1")
    _finite_number(request["fps"], "fps", positive=True)
    _integer(request["steps"], "steps", minimum=1)
    _integer(request["seed"], "seed", minimum=0, maximum=2**32 - 1)
    if type(request["stream_weights"]) is not bool:
        raise ValueError("stream_weights must be a bool")
    _finite_number(request["cfg_scale"], "cfg_scale")
    _finite_number(request["stg_scale"], "stg_scale")
    return dict(request)


def build_plan(request, *, engine, model, output, text_encoder=None):
    """Return argv, environment and provenance for an offline LTX dev run.

    All checks are read-only. Path existence is time-sensitive; this plan is
    neither an execution authorization nor complete resource/precision proof.
    """
    checked = _checked_request(request)
    engine_path = _local_file(engine, "engine", executable=True)
    model_path = _local_directory(model, "model")
    output_path = _unused_output(output)

    if checked["profile"].startswith("ltx-2.3-"):
        video_decoder = "conv"
        if text_encoder is None:
            raise ValueError("LTX 2.3 requires an explicit local text_encoder directory")
        encoder_path = _local_directory(text_encoder, "text_encoder")
        encoder_source = "explicit-local-gemma3"
    else:
        video_decoder = "diffusion"
        if text_encoder is not None:
            raise ValueError("LTX 2.5 uses its pack-local Gemma4; text_encoder must be None")
        # Upstream chooses Gemma4 only if BOTH files exist. If either is
        # missing, it silently selects Gemma3 and may use its remote default.
        for filename in ("text_encoder.safetensors", "text_encoder_config.json"):
            _local_file(model_path / filename, f"LTX 2.5 pack {filename}")
        encoder_path = model_path
        encoder_source = "pack-local-gemma4"

    # Use --key=value for all values: argparse otherwise treats a prompt that
    # begins with '-' as another option. No shell is involved in this plan.
    argv = [
        str(engine_path),
        "generate",
        "--one-stage",
        "--dev-transformer=transformer-dev.safetensors",
        f"--video-decoder={video_decoder}",
        f"--model={model_path}",
        f"--gemma={encoder_path}",
        f"--output={output_path}",
        f"--prompt={checked['prompt']}",
        f"--negative-prompt={checked['negative_prompt']}",
        f"--width={checked['width']}",
        f"--height={checked['height']}",
        f"--frames={checked['frames']}",
        f"--frame-rate={checked['fps']}",
        f"--steps={checked['steps']}",
        f"--seed={checked['seed']}",
        f"--cfg-scale={checked['cfg_scale']}",
        f"--stg-scale={checked['stg_scale']}",
    ]
    if checked["stream_weights"]:
        argv.append("--low-ram")

    environment = {
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    provenance = {
        "task": "D-VIDEO-MODELS-01-LTX",
        "task_revision": "r1",
        "upstream_repository": "dgrauet/ltx-2-mlx",
        "upstream_commit_from_task": _UPSTREAM_COMMIT,
        "profile": checked["profile"],
        "schema_version": checked["schema_version"],
        "engine": str(engine_path),
        "model": str(model_path),
        "output": str(output_path),
        "text_encoder": str(encoder_path),
        "text_encoder_source": encoder_source,
        "video_decoder": video_decoder,
        "stream_weights": checked["stream_weights"],
        "weight_loading": "transformer-block-streaming" if checked["stream_weights"] else "eager",
        "request": checked,
        "plan_only": True,
        "resources_and_precision_verified": False,
    }
    return {"argv": argv, "environment": environment, "provenance": provenance}
