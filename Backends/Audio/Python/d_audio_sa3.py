"""Real SA3 MLX adapter for AUDIO1.

The module itself is stdlib-only. Vendor, NumPy, and MLX imports occur only
inside ``run_inference`` after launch configuration, weights, and provenance
have been verified by the CLI.
"""

from __future__ import annotations

from array import array
from dataclasses import dataclass
import gc
import hashlib
import importlib
from importlib import abc as importlib_abc
from importlib import util as importlib_util
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
    mlx_allocations: dict[str, Any]


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


def _mx_value(mx: Any, name: str) -> int | None:
    getter = getattr(mx, name, None)
    if getter is None:
        return None
    try:
        value = getter()
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return None
        return value
    except Exception:
        return None


def _measure(mx: Any, peak: int | None, phase: str) -> tuple[dict[str, Any], int | None]:
    active = _mx_value(mx, "get_active_memory")
    cache = _mx_value(mx, "get_cache_memory")
    reported_peak = _mx_value(mx, "get_peak_memory")
    # A true MLX peak is reported only from the dedicated getter. Active
    # snapshots are a separately labelled lower bound and never promoted.
    peak = reported_peak
    if peak is not None and active is not None and peak < active:
        peak = None
        reported_peak = None
    available = sum(value is not None for value in (active, cache, reported_peak))
    return {
        "measurementKind": (
            "mlx-allocator" if available == 3 else
            "partial-mlx-allocator" if available else
            "unavailable"
        ),
        "measurementPhase": phase,
        "activeBytes": active,
        "cacheBytes": cache,
        "peakBytes": peak,
        "observedActiveLowerBoundBytes": active,
    }, peak


def _release(mx: Any) -> None:
    gc.collect()
    synchronize = getattr(mx, "synchronize", None)
    if synchronize is None:
        raise RuntimeError("MLX synchronize is unavailable during cleanup")
    synchronize()
    clear = getattr(mx, "clear_cache", None)
    if clear is None:
        raise RuntimeError("MLX clear_cache is unavailable during cleanup")
    clear()


class _VerifiedVendorLoader(importlib_abc.MetaPathFinder, importlib_abc.Loader):
    """Bounded source-only importer for the provenance-listed Python subset."""

    def __init__(self, vendor_directory: Path, checked: dict[str, str]) -> None:
        self.vendor_directory = vendor_directory
        self.checked = checked
        self.modules: dict[str, tuple[str, bool]] = {}
        self.owned: dict[str, Any] = {}
        for relative in checked:
            if not relative.endswith(".py"):
                continue
            pure = PurePosixPath(relative)
            if pure.name == "__init__.py":
                name = ".".join(pure.parts[:-1])
                is_package = True
            else:
                name = ".".join((*pure.parts[:-1], pure.stem))
                is_package = False
            if not name or name in self.modules:
                raise ContractError("vendor provenance has ambiguous Python module names", "configuration")
            self.modules[name] = (relative, is_package)
        self.roots = {name.split(".", 1)[0] for name in self.modules}
        self.active = False

    def start(self) -> None:
        conflicts = sorted(
            name for name in sys.modules
            if name in self.modules or name == "models" or name.startswith("models.")
        )
        if conflicts:
            raise ContractError(f"preloaded vendor module is forbidden: {conflicts[0]}", "configuration")
        sys.meta_path.insert(0, self)
        self.active = True

    def close(self) -> None:
        if self.active:
            try:
                sys.meta_path.remove(self)
            except ValueError:
                pass
            self.active = False
        for name, module in sorted(self.owned.items(), key=lambda item: item[0].count("."), reverse=True):
            if sys.modules.get(name) is module:
                del sys.modules[name]
        self.owned.clear()

    def find_spec(self, fullname: str, path: Any = None, target: Any = None) -> Any:
        entry = self.modules.get(fullname)
        if entry is None:
            if any(fullname == root or fullname.startswith(root + ".") for root in self.roots):
                raise ModuleNotFoundError(f"unlisted vendor module is forbidden: {fullname}")
            return None
        relative, is_package = entry
        origin = str(self.vendor_directory.joinpath(*PurePosixPath(relative).parts))
        return importlib_util.spec_from_loader(fullname, self, origin=origin, is_package=is_package)

    def create_module(self, spec: Any) -> None:
        return None

    def exec_module(self, module: Any) -> None:
        entry = self.modules.get(module.__name__)
        if entry is None:
            raise ImportError(f"unlisted vendor module: {module.__name__}")
        relative, is_package = entry
        source_path = self.vendor_directory.joinpath(*PurePosixPath(relative).parts)
        raw, _ = read_regular_file(source_path, max_bytes=1024 * 1024, label=f"vendor source {relative}")
        if hashlib.sha256(raw).hexdigest() != self.checked[relative]:
            raise ContractError(f"vendor source changed before execution: {relative}", "configuration")
        try:
            code = compile(raw, str(source_path), "exec", dont_inherit=True)
        except (SyntaxError, ValueError, OverflowError) as exc:
            raise ContractError(f"cannot compile verified vendor source {relative}: {exc}", "configuration") from exc
        module.__file__ = str(source_path)
        module.__cached__ = None
        if is_package:
            module.__path__ = [str(source_path.parent)]
        self.owned[module.__name__] = module
        exec(code, module.__dict__)

    def import_module(self, name: str) -> Any:
        if name not in self.modules:
            raise ContractError(f"vendor module {name} is not listed in provenance", "configuration")
        return importlib.import_module(name)


def _vendor_import(name: str, vendor_directory: Path, checked: dict[str, str]) -> Any:
    """One-shot source-only import used by bounded CPU provenance probes."""
    loader = _VerifiedVendorLoader(vendor_directory, checked)
    loader.start()
    try:
        return loader.import_module(name)
    finally:
        loader.close()


class _SA3LayerWeights:
    """The admitted NPZ, original tensors, one layer at a time; no derived copy."""
    def __init__(self, path, cancelled):
        import numpy as np
        self.path, self.cancelled = path, cancelled
        self.identity = self.current()
        with np.load(path, allow_pickle=False) as arrays:
            self.keys = tuple(arrays.files)
        if len(set(self.keys)) != len(self.keys):
            raise ContractError("duplicate NPZ tensors", "configuration")
        self.verify()

    def current(self):
        info = os.stat(self.path, follow_symlinks=False)
        return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

    def verify(self):
        _check_cancel(self.cancelled)
        if self.current() != self.identity:
            raise ContractError("SA3 weights changed during execution", "configuration")

    def read(self, include):
        import numpy as np
        import mlx.core as mx
        self.verify()
        values = {}
        with np.load(self.path, allow_pickle=False) as arrays:
            for key in self.keys:
                if include(key):
                    self.verify()
                    value = arrays[key]
                    if value.dtype not in (np.float16, np.float32):
                        raise ContractError("unexpected SA3 tensor dtype", "configuration")
                    values[key] = mx.array(value)
        self.verify()
        return values

    def install(self, module, values):
        import mlx.core as mx
        from mlx.utils import tree_flatten
        expected = dict(tree_flatten(module.parameters()))
        if set(values) != set(expected) or any(values[k].shape != expected[k].shape for k in expected):
            raise ContractError("SA3 layer differs from the fixed architecture", "configuration")
        module.load_weights(list(values.items()), strict=True)
        mx.eval(module.parameters())
        self.verify()


def _layered_text(path, t5, cancelled):
    import mlx.core as mx
    import mlx.nn as nn
    import numpy as np
    import sentencepiece as spm
    weights = _SA3LayerWeights(path, cancelled)
    with np.load(path, allow_pickle=False) as arrays:
        cfg = t5.T5GemmaConfig.from_json_bytes(arrays["META"].tobytes())
        tokenizer = spm.SentencePieceProcessor()
        tokenizer.LoadFromSerializedProto(arrays["TOKENIZER_MODEL"].tobytes())
    encoder = t5._Encoder(cfg)
    shared = weights.read(lambda key: key not in ("META", "TOKENIZER_MODEL") and not key.startswith("layers."))
    encoder.embed_tokens.weight = shared["embed_tokens.weight"]
    encoder.norm = shared["norm.weight"]
    if "rope_inv_freq" in shared:
        encoder.rope_inv_freq = shared["rope_inv_freq"].astype(mx.float32)
    norms = ("pre_self_attn_layernorm", "post_self_attn_layernorm", "pre_feedforward_layernorm", "post_feedforward_layernorm")
    class Layer(nn.Module):
        def __init__(self, index):
            super().__init__(); self.index = index
        def __call__(self, *args):
            weights.verify()
            rng = list(mx.random.state); mx.eval(rng)
            layer = None
            try:
                layer = t5._EncoderLayer(cfg)
                prefix = f"layers.{self.index}."
                values = {key[len(prefix):]: value for key, value in weights.read(lambda k: k.startswith(prefix)).items()}
                for name in norms:
                    values[name] = values.pop(name + ".weight")
                weights.install(layer, values)
                result = layer(*args); mx.eval(result); weights.verify()
                return result
            finally:
                mx.random.state = rng; layer = None
                mx.clear_cache()
    encoder.layers = [Layer(index) for index in range(cfg.num_hidden_layers)]
    mx.eval(encoder.parameters()); weights.verify()
    return t5.T5Gemma(encoder, cfg, tokenizer)


def _layered_dit(path, dit_module, latent_count, cancelled):
    import mlx.core as mx
    import mlx.nn as nn
    weights = _SA3LayerWeights(path, cancelled)
    model = dit_module.DiT(T_lat=latent_count)
    # Keep the vendor ContinuousTransformer loop unchanged, including local
    # conditioning before each block. The proxy owns one block between its two calls.
    class Layer(nn.Module):
        def __init__(self, index):
            super().__init__(); self.index = index; self._loaded = None
        def to_local_embed(self, local):
            weights.verify()
            rng = list(mx.random.state); mx.eval(rng)
            try:
                self._loaded = dit_module.TransformerBlock()
                prefix = f"transformer.layers.{self.index}."
                values = {key[len(prefix):]: value.astype(mx.float16)
                    for key, value in weights.read(lambda k: k.startswith(prefix)).items()}
                weights.install(self._loaded, values)
                result = self._loaded.to_local_embed(local); mx.eval(result); weights.verify()
                return result
            except BaseException:
                self._loaded = None; mx.clear_cache(); raise
            finally:
                mx.random.state = rng
        def __call__(self, *args):
            try:
                weights.verify()
                if self._loaded is None:
                    raise ContractError("SA3 block conditioning was not evaluated", "configuration")
                result = self._loaded(*args); mx.eval(result); weights.verify()
                return result
            finally:
                self._loaded = None; mx.clear_cache()
    model.transformer.layers = [Layer(index) for index in range(dit_module.DEPTH)]
    shared = {key: value.astype(mx.float16) for key, value in weights.read(
        lambda k: not k.startswith(("transformer.layers.", "cond."))).items()}
    # The pinned resident loader ignores this unused serialized rotary tensor;
    # DiT uses its original fixed RoPE kernel and generated Fourier frequencies.
    shared.pop("transformer.rotary_pos_emb.inv_freq", None)
    shared["timestep_features.freqs"] = model.timestep_features.freqs
    weights.install(model, shared)
    return model


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
    checked_vendor = verify_vendor(vendor_directory)
    mx = None
    vendor_loader: _VerifiedVendorLoader | None = None
    timings: dict[str, float] = {}
    allocations: dict[str, Any] = {
        "measurementKind": "unavailable", "measurementPhase": "notMeasured",
        "activeBytes": None, "cacheBytes": None, "peakBytes": None,
    }
    peak: int | None = None
    result: InferenceResult | None = None
    try:
        # External dependencies are resolved before vendor code is importable,
        # preventing an unlisted file in the vendor root from shadowing them.
        np = importlib.import_module("numpy")
        mx = importlib.import_module("mlx.core")
        importlib.import_module("sentencepiece")
        if any(name == "models" or name.startswith("models.") for name in sys.modules):
            raise ContractError("a models package was loaded before pinned vendor activation", "configuration")
        vendor_loader = _VerifiedVendorLoader(vendor_directory, checked_vendor)
        vendor_loader.start()
        pipeline = vendor_loader.import_module("models.defs.sa3_pipeline")
        t5_module = vendor_loader.import_module("models.defs.t5gemma_mlx")
        _cap, dit_name, codec = PROFILES[next(
            profile for profile, values in PROFILES.items()
            if f"MLX/{values[1]}" == manifest.entries[0].relative_path
        )]
        dit_module = vendor_loader.import_module(
            "models.defs.dit_mlx_medium" if codec == "same_l" else "models.defs.dit_mlx",
        )
        decoder_module = vendor_loader.import_module(f"models.defs.{codec}_decoder")
        encoder_module = vendor_loader.import_module(f"models.defs.{codec}_encoder")
        paths = {item.relative_path: model_directory.joinpath(*PurePosixPath(item.relative_path).parts)
                 for item in manifest.entries}
        dit_path = paths[f"MLX/{dit_name}"]
        text_path = paths["MLX/t5gemma_f16.npz"]
        encoder_path = paths[f"MLX/{codec}_encoder_f32.npz"]
        decoder_path = paths[f"MLX/{codec}_decoder_f32.npz"]

        progress("encodingText", 0, 1)
        started = time.monotonic()
        layered = request.raw.get("loadingStrategy") == "ssdLayered"
        if layered and codec != "same_s":
            raise ContractError("layered SA3 requires the fixed small architecture", "configuration")
        text_encoder = (_layered_text(text_path, t5_module, cancelled) if layered
                        else t5_module.T5Gemma.from_npz(str(text_path)))
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
        allocations, peak = _measure(mx, peak, "afterTextEncodingBeforeCacheCleanup")
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
            allocations, peak = _measure(mx, peak, "afterSourceEncodingBeforeCacheCleanup")
            _release(mx)
            _check_cancel(cancelled)

        progress("denoising", 0, request.steps)
        started = time.monotonic()
        dit = (_layered_dit(dit_path, dit_module, request.latent_count, cancelled) if layered
               else dit_module.load_dit(str(dit_path), T_lat=request.latent_count, dtype=dtype,
                                      compile_=False, lora_specs=None, num_steps=request.steps))
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
        allocations, peak = _measure(mx, peak, "afterDenoisingBeforeCacheCleanup")
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
        allocations, peak = _measure(mx, peak, "afterDecodeBeforeFinalCleanup")
        output_samples = array("f")
        output_samples.frombytes(generated.astype(np.float32, copy=False).reshape(-1).tobytes())
        result = InferenceResult(output_samples, timings, allocations)
        return result
    except (ContractError, CancelledError):
        raise
    except Exception as exc:
        raise RuntimeError(f"SA3 engine failure: {exc}") from exc
    finally:
        cleanup_failure: Exception | None = None
        if mx is not None:
            try:
                # Drop all final MLX/model/NumPy references before synchronize
                # and cache release. The stdlib output array remains owned.
                text_encoder = embeds = mask = padded = padding = seconds_embedder = None
                cross_attn = global_cond = null_cross = seconds = None
                encoder = audio = patches = init_latents = None
                dit = sigmas = key = pure_noise = noise = local_add = paste_back = None
                latent_mask = masked = latents = latents_fp32 = None
                decoder = decoded_patches = decoded = generated = preserved = even = None
                _release(mx)
                after_cleanup, peak = _measure(mx, peak, "afterFinalCleanup")
                if result is not None:
                    result.mlx_allocations["cleanupStatus"] = "completed"
                    result.mlx_allocations["postCleanup"] = after_cleanup
            except Exception as cleanup_exc:
                cleanup_failure = cleanup_exc
        if vendor_loader is not None:
            vendor_loader.close()
        if cleanup_failure is not None:
            raise RuntimeError(f"MLX cleanup failure: {cleanup_failure}") from cleanup_failure
