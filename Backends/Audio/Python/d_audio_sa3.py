"""Real SA3 MLX adapter for AUDIO1.

The module itself is stdlib-only. Vendor, NumPy, and MLX imports occur only
inside ``run_inference`` after launch configuration, weights, and provenance
have been verified by the CLI.
"""

from __future__ import annotations

from dataclasses import dataclass
import gc
import hashlib
import importlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import sys
import time
from typing import Any, Callable

from d_audio_contract import (
    AudioRequest,
    ContractError,
    PROFILES,
    SAMPLE_RATE,
    SAMPLES_PER_LATENT,
    VENDOR_REPOSITORY,
    VENDOR_REVISION,
    WaveData,
    WeightManifest,
    decode_strict_json,
    hash_regular_file,
    read_regular_file,
)


VENDOR_PROVENANCE_SHA256 = "f5332dfbd2b91d79b23dcacb0bc6cbaccba99a947e361aa092e9272cf83e684b"


class CancelledError(Exception):
    pass


@dataclass
class InferenceResult:
    samples: Any
    timings_seconds: dict[str, float]
    mlx_allocations: dict[str, int]


def verify_vendor(vendor_directory: Path) -> dict[str, str]:
    provenance_path = vendor_directory / "provenance.json"
    raw, _ = read_regular_file(provenance_path, max_bytes=1024 * 1024, label="vendor provenance")
    if hashlib.sha256(raw).hexdigest() != VENDOR_PROVENANCE_SHA256:
        raise ContractError("vendor provenance bytes do not match the pinned runtime manifest", "configuration")
    provenance = decode_strict_json(raw, label="vendor provenance")
    if provenance.get("repository") != VENDOR_REPOSITORY or provenance.get("revision") != VENDOR_REVISION:
        raise ContractError("vendor repository/revision mismatch", "configuration")
    files = provenance.get("files")
    if not isinstance(files, dict) or not files:
        raise ContractError("vendor provenance has no hash list", "configuration")
    checked: dict[str, str] = {}
    for relative, expected_digest in files.items():
        pure = PurePosixPath(relative) if isinstance(relative, str) else None
        if pure is None or pure.is_absolute() or ".." in pure.parts or not pure.parts:
            raise ContractError("vendor provenance contains an unsafe path", "configuration")
        if not isinstance(expected_digest, str) or len(expected_digest) != 64:
            raise ContractError("vendor provenance contains an invalid digest", "configuration")
        candidate = vendor_directory.joinpath(*pure.parts)
        actual = hash_regular_file(candidate, expected_size=None, label=f"vendor file {relative}")
        if actual != expected_digest:
            raise ContractError(f"vendor file digest mismatch: {relative}", "configuration")
        checked[relative] = actual
    required_modules = {
        "models/__init__.py", "models/defs/__init__.py", "models/defs/sa3_pipeline.py",
        "models/defs/t5gemma_mlx.py", "models/defs/dit_mlx.py", "models/defs/dit_mlx_medium.py",
        "models/defs/same_s_encoder.py", "models/defs/same_s_decoder.py",
        "models/defs/same_l_encoder.py", "models/defs/same_l_decoder.py",
    }
    if not required_modules.issubset(checked):
        raise ContractError("vendor provenance omits required runtime modules", "configuration")
    return checked


def _check_cancel(cancelled: Callable[[], bool]) -> None:
    if cancelled():
        raise CancelledError("audio generation cancelled")


def _mx_value(mx: Any, name: str) -> int:
    getter = getattr(mx, name, None)
    if getter is None:
        return 0
    try:
        value = int(getter())
        return max(0, value)
    except Exception:
        return 0


def _measure(mx: Any, peak: int) -> tuple[dict[str, int], int]:
    active = _mx_value(mx, "get_active_memory")
    cache = _mx_value(mx, "get_cache_memory")
    reported_peak = _mx_value(mx, "get_peak_memory")
    peak = max(peak, active, reported_peak)
    return {"activeBytes": active, "cacheBytes": cache, "peakBytes": peak}, peak


def _release(mx: Any) -> None:
    gc.collect()
    synchronize = getattr(mx, "synchronize", None)
    if synchronize is not None:
        synchronize()
    clear = getattr(mx, "clear_cache", None)
    if clear is not None:
        clear()


def run_inference(
    request: AudioRequest,
    manifest: WeightManifest,
    model_directory: Path,
    vendor_directory: Path,
    source_wave: WaveData | None,
    progress: Callable[[str, int, int], None],
    cancelled: Callable[[], bool],
) -> InferenceResult:
    """Execute pinned SA3 math. Callers must complete all verification first."""
    _check_cancel(cancelled)
    vendor_text = str(vendor_directory)
    if vendor_text in sys.path:
        raise ContractError("vendor directory is already present in import path", "configuration")
    sys.path.insert(0, vendor_text)
    mx = None
    timings: dict[str, float] = {}
    allocations = {"activeBytes": 0, "cacheBytes": 0, "peakBytes": 0}
    peak = 0
    try:
        # These are the first non-stdlib imports in the provider.
        np = importlib.import_module("numpy")
        mx = importlib.import_module("mlx.core")
        pipeline = importlib.import_module("models.defs.sa3_pipeline")
        t5_module = importlib.import_module("models.defs.t5gemma_mlx")
        _cap, dit_name, codec = PROFILES[next(
            profile for profile, values in PROFILES.items()
            if f"MLX/{values[1]}" == manifest.entries[0].relative_path
        )]
        dit_module = importlib.import_module(
            "models.defs.dit_mlx_medium" if codec == "same_l" else "models.defs.dit_mlx"
        )
        encoder_module = importlib.import_module(f"models.defs.{codec}_encoder")
        decoder_module = importlib.import_module(f"models.defs.{codec}_decoder")
        paths = {item.relative_path: model_directory.joinpath(*PurePosixPath(item.relative_path).parts)
                 for item in manifest.entries}
        dit_path = paths[f"MLX/{dit_name}"]
        text_path = paths["MLX/t5gemma_f16.npz"]
        encoder_path = paths[f"MLX/{codec}_encoder_f32.npz"]
        decoder_path = paths[f"MLX/{codec}_decoder_f32.npz"]

        progress("encodingText", 0, 1)
        started = time.monotonic()
        text_encoder = t5_module.T5Gemma.from_npz(str(text_path))
        tokens = text_encoder.tokenizer.Encode(request.prompt)
        if len(tokens) > 256:
            raise ContractError("prompt exceeds the SA3 tokenizer limit of 256 tokens")
        embeds, mask = text_encoder.encode([request.prompt], max_len=256)
        mx.eval(embeds, mask)
        padding, seconds_embedder = pipeline.load_conditioner_from_npz(str(dit_path), prefix="cond.")
        dtype = mx.float16
        embeds = embeds.astype(dtype)
        padded = pipeline.apply_prompt_padding(embeds, mask, padding.astype(dtype))
        seconds = seconds_embedder(request.duration_seconds).astype(dtype)
        cross_attn = mx.concatenate([padded, seconds], axis=1)
        global_cond = seconds[:, 0, :]
        null_cross = mx.zeros_like(cross_attn) if request.guidance_scale != 1.0 else None
        mx.eval(cross_attn, global_cond, *(() if null_cross is None else (null_cross,)))
        timings["encodingText"] = time.monotonic() - started
        progress("encodingText", 1, 1)
        del text_encoder, embeds, mask, padded, padding, seconds_embedder
        allocations, peak = _measure(mx, peak)
        _release(mx)
        _check_cancel(cancelled)

        init_latents = None
        if source_wave is not None:
            progress("encodingSource", 0, 1)
            started = time.monotonic()
            encoder = encoder_module.load_model(weights_path=str(encoder_path), dtype=mx.float32, compile_=False)
            pad_modulo = 32 if codec == "same_s" else 16
            encode_latents = request.latent_count
            if (encode_latents * 16) % pad_modulo:
                encode_latents = math.ceil((encode_latents * 16) / pad_modulo) * pad_modulo // 16
            target_samples = encode_latents * SAMPLES_PER_LATENT
            audio = np.asarray(source_wave.samples, dtype=np.float32).reshape(source_wave.frame_count, 2).T
            if audio.shape[-1] < target_samples:
                audio = np.pad(audio, ((0, 0), (0, target_samples - audio.shape[-1])))
            else:
                audio = audio[:, :target_samples]
            audio = audio[None, ...]
            length = audio.shape[-1] // 256
            patches = audio.reshape(1, 2, length, 256).transpose(0, 1, 3, 2).reshape(1, 512, length)
            init_latents = encoder(mx.array(patches))[..., :request.latent_count]
            mx.eval(init_latents)
            init_latents = init_latents.astype(dtype)
            timings["encodingSource"] = time.monotonic() - started
            progress("encodingSource", 1, 1)
            del encoder, audio, patches
            allocations, peak = _measure(mx, peak)
            _release(mx)
            _check_cancel(cancelled)

        progress("denoising", 0, request.steps)
        started = time.monotonic()
        dit = dit_module.load_dit(str(dit_path), T_lat=request.latent_count, dtype=dtype,
                                  compile_=False, lora_specs=None, num_steps=request.steps)
        sigmas = pipeline.build_pingpong_schedule(request.steps, sigma_max=request.strength, use_logsnr_shift=True)
        key = mx.random.key(request.seed)
        pure_noise = mx.random.normal((1, 256, request.latent_count), dtype=dtype, key=key)
        if init_latents is not None and request.operation == "variation":
            noise = init_latents * (1.0 - request.strength) + pure_noise * request.strength
        else:
            noise = pure_noise
        local_add = None
        paste_back = None
        if request.operation == "inpaint":
            assert init_latents is not None and request.effective_latent_region is not None
            start, end = request.effective_latent_region
            mask_np = np.ones((1, 1, request.latent_count), dtype=np.float32)
            mask_np[:, :, start:end] = 0
            latent_mask = mx.array(mask_np)
            masked = init_latents.astype(mx.float32) * latent_mask
            local_add = mx.concatenate([latent_mask, masked], axis=1).transpose(0, 2, 1).astype(dtype)
            paste_back = (init_latents, latent_mask)

        def model_fn(x: Any, t: Any) -> Any:
            if request.guidance_scale == 1.0:
                return dit(x, t, cross_attn, global_cond, local_add_cond=local_add)
            x2 = mx.concatenate([x, x], axis=0)
            t2 = mx.concatenate([t, t], axis=0)
            cross2 = mx.concatenate([cross_attn, null_cross], axis=0)
            global2 = mx.concatenate([global_cond, global_cond], axis=0)
            local2 = None if local_add is None else mx.concatenate([local_add, local_add], axis=0)
            cond_v, uncond_v = mx.split(dit(x2, t2, cross2, global2, local_add_cond=local2), 2, axis=0)
            sigma = t.reshape(-1, 1, 1).astype(mx.float32)
            cond_d = x.astype(mx.float32) - cond_v.astype(mx.float32) * sigma
            uncond_d = x.astype(mx.float32) - uncond_v.astype(mx.float32) * sigma
            guided = cond_d + (request.guidance_scale - 1.0) * (cond_d - uncond_d)
            return ((x.astype(mx.float32) - guided) / sigma).astype(x.dtype)

        def on_step(completed: int, total: int) -> None:
            _check_cancel(cancelled)
            progress("denoising", completed, total)

        latents = pipeline.sample_flow_pingpong(model_fn, noise, sigmas, seed=request.seed + 1,
                                                paste_back=paste_back, on_step=on_step, before_step=None)
        mx.eval(latents)
        timings["denoising"] = time.monotonic() - started
        del dit, model_fn, noise, pure_noise, sigmas
        allocations, peak = _measure(mx, peak)
        _release(mx)
        _check_cancel(cancelled)

        progress("decoding", 0, 1)
        started = time.monotonic()
        decoder = decoder_module.load_model(weights_path=str(decoder_path), dtype=mx.float32, compile_=False)
        latents_fp32 = latents.astype(mx.float32)
        chunk, overlap = ((8, 2) if codec == "same_s" else (128, 8))
        kernel = chunk + 2 * overlap
        if request.latent_count > kernel:
            decoded_patches = decoder_module.decode_chunked(decoder, latents_fp32, chunk, overlap)
        elif request.latent_count % 2 == 0 or codec == "same_l":
            decoded_patches = decoder(latents_fp32)
        elif request.latent_count > 6:
            decoded_patches = decoder_module.decode_chunked(decoder, latents_fp32, 2, 2)
        else:
            even = mx.concatenate([latents_fp32, latents_fp32[..., -1:]], axis=-1)
            decoded_patches = decoder(even)[..., :request.latent_count * 16]
        decoded = pipeline.patched_decode(decoded_patches, patch_size=256, channels=2)
        mx.eval(decoded)
        generated = np.array(decoded.astype(mx.float32))[0, :, :request.requested_frames].T.copy()
        if generated.shape != (request.requested_frames, 2):
            raise ContractError("decoder did not produce the requested frame count", "output")
        if request.operation == "inpaint":
            assert source_wave is not None and request.edit_region is not None
            preserved = np.asarray(source_wave.samples, dtype=np.float32).reshape(source_wave.frame_count, 2).copy()
            start, end = request.edit_region.start_frame, request.edit_region.end_frame
            preserved[start:end, :] = generated[start:end, :]
            generated = preserved
        timings["decoding"] = time.monotonic() - started
        progress("decoding", 1, 1)
        allocations, peak = _measure(mx, peak)
        allocations["peakBytes"] = peak
        return InferenceResult(generated.reshape(-1), timings, allocations)
    except (ContractError, CancelledError):
        raise
    except Exception as exc:
        raise RuntimeError(f"SA3 engine failure: {exc}") from exc
    finally:
        if mx is not None:
            try:
                _release(mx)
            except Exception:
                pass
        if sys.path and sys.path[0] == vendor_text:
            del sys.path[0]
