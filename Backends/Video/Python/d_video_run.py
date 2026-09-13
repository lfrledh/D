"""D's offline Wan T2V process: immutable request -> private RGB8 spool + record.

The host owns admission, process cancellation/drain and MP4 publication. No model
download, audio track, UI, nested subprocess or implicit parameter adjustment.
"""
from __future__ import annotations

import argparse
import gc
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import resource
import signal
import sys
import time
import uuid

from d_video_model import PreparedModel, read_json, read_snapshot
from d_video_prepare import REVISION, checked_local, exclusive_json, identity, digest

PROFILE = "wan21-t2v-1.3b-bf16-v1"
SCHEMA = "d.video.frames.v1"
TOKENIZER_DIGESTS = {
    "special_tokens_map.json": "7b8a9f5040adb67b5805abdfd42c1f8d0f3d0e711f10726580eb3789cd0ad61d",
    "spiece.model": "e3909a67b780650b35cf529ac782ad2b6b26e6d1f849d3fbb6a872905f452458",
    "tokenizer.json": "6e197b4d3dbd71da14b4eb255f4fa91c9c1f2068b20a2de2472967ca3d22602b",
    "tokenizer_config.json": "ed9a3a8b0faa71a70a32847e0435fe036e6e112d4df4edb7bb48a921e344dc05",
}
_cancelled = False


def check_cancel():
    if _cancelled:
        raise InterruptedError("Video cancellation requested; current compute boundary reached")


def validate_request(value: dict) -> dict:
    keys = {"schemaVersion", "runID", "profile", "revision", "prompt", "negativePrompt",
            "width", "height", "frameCount", "fpsNumerator", "fpsDenominator", "steps",
            "guidanceScale", "shift", "seed", "memoryLimitBytes"}
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError("Video request fields must exactly match the versioned contract")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise ValueError("Unsupported request version")
    if value["profile"] != PROFILE or value["revision"] != REVISION:
        raise ValueError("Unsupported model revision or execution profile")
    if not isinstance(value["runID"], str) or str(uuid.UUID(value["runID"])) != value["runID"]:
        raise ValueError("runID must be a canonical UUID")
    if (not isinstance(value["prompt"], str) or not value["prompt"].strip()
            or not isinstance(value["negativePrompt"], str)):
        raise ValueError("Explicit positive and negative text conditions are required")
    for key in ("width", "height", "frameCount", "fpsNumerator", "fpsDenominator", "steps", "memoryLimitBytes"):
        if type(value[key]) is not int or not 0 < value[key] <= 2**63 - 1:
            raise ValueError("Invalid positive integer: " + key)
    if value["width"] % 16 or value["height"] % 16 or (value["frameCount"] - 1) % 4:
        raise ValueError("Wan requires width/height multiples of 16 and frameCount = 4n+1")
    if (value["fpsNumerator"] > 2**31-1 or value["fpsDenominator"] > 2**31-1
            or value["frameCount"] * value["fpsDenominator"] > 2**63-1
            or value["width"] * value["height"] * value["frameCount"] * 3 > 2**63-1):
        raise ValueError("Video byte count or rational timeline exceeds representation")
    if max((value["frameCount"] - 1) // 4 + 1, value["width"] // 16, value["height"] // 16) > 1024:
        raise ValueError("Requested latent axis exceeds this model's positional table")
    if type(value["seed"]) is not int or not 0 <= value["seed"] <= 2**32-1:
        raise ValueError("This backend accepts explicit UInt32 seeds")
    for key in ("guidanceScale", "shift"):
        if type(value[key]) not in (float, int) or not math.isfinite(value[key]) or value[key] <= 0:
            raise ValueError("Invalid finite positive control: " + key)
    return value


def clean_text(value: str) -> str:
    import ftfy
    return re.sub(r"\s+", " ", html.unescape(html.unescape(ftfy.fix_text(value)))).strip()


def tokenize_conditions(directory: Path, request: dict):
    from transformers import AutoTokenizer
    directory = checked_local(directory)
    # Required local tokenizer resources are explicit. Nothing may trigger remote code.
    required = TOKENIZER_DIGESTS
    snapshots = {name: identity(checked_local(directory / name)) for name in required}
    for name, expected in TOKENIZER_DIGESTS.items():
        if digest(directory / name) != expected or identity(directory / name) != snapshots[name]:
            raise ValueError("Tokenizer differs from the pinned model revision: " + name)
    tokenizer = AutoTokenizer.from_pretrained(str(directory), local_files_only=True, trust_remote_code=False)
    results = []
    for field in ("prompt", "negativePrompt"):
        cleaned = clean_text(request[field])
        unpadded = tokenizer(cleaned, truncation=False, padding=False, add_special_tokens=True)
        count = len(unpadded["input_ids"])
        if count > 512:
            raise ValueError(field + " exceeds the model's 512-token condition format; no truncation performed")
        tokens = tokenizer(cleaned, truncation=False, padding="max_length", max_length=512,
                           add_special_tokens=True, return_tensors="np")
        if tokens["input_ids"].shape != (1, 512) or int(tokens["attention_mask"].sum()) != count:
            raise ValueError("Local tokenizer produced an inconsistent condition")
        results.append((tokens, count, cleaned))
    if any(identity(directory / name) != snap for name, snap in snapshots.items()):
        raise ValueError("Tokenizer changed during condition encoding")
    return results


def run(request_path: Path, model_path: Path, tokenizer_path: Path, output: Path) -> dict:
    request, request_digest, request_identity = read_snapshot(request_path)
    request = validate_request(request)
    model = PreparedModel(model_path)
    conditions = tokenize_conditions(tokenizer_path, request)
    output = checked_local(output)
    if not output.parent.is_dir():
        raise ValueError("Output parent must be an existing caller-owned task directory")
    output.mkdir(mode=0o700)  # Exclusive; no overwrite of previous diagnostic or media files.
    started = time.monotonic()
    stages = []
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Vendor"))
    import mlx.core as mx
    import numpy as np
    from wan21.config import WanModelConfig
    from wan21.text_encoder import T5Encoder
    from wan21.wan_2 import WanModel
    from wan21.vae import WanVAE
    from wan21.scheduler import FlowUniPCScheduler

    mx.set_memory_limit(request["memoryLimitBytes"])
    mx.set_cache_limit(64 * 1024 * 1024)
    mx.reset_peak_memory()

    def observe(stage, completed=0, total=1):
        check_cancel()
        record = {"stage": stage, "completed": completed, "total": total,
                  "seconds": time.monotonic() - started, "activeBytes": mx.get_active_memory(),
                  "cacheBytes": mx.get_cache_memory(), "peakBytes": mx.get_peak_memory(),
                  "peakRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
        stages.append(record)
        print(json.dumps({"schema": SCHEMA, "type": "progress", "runID": request["runID"], **record}), flush=True)

    def loading(role):
        def checkpoint(index, total):
            check_cancel()
            if index % 50 == 0:
                observe("load-" + role, index, total)
        return checkpoint

    config = WanModelConfig.wan21_t2v_1_3b()
    observe("load-text")
    encoder = model.load("text", T5Encoder(), loading("text"))
    contexts = []
    for index, (tokens, count, cleaned) in enumerate(conditions):
        observe("encode-text", index, 2)
        embeddings = encoder(mx.array(tokens["input_ids"]), mask=mx.array(tokens["attention_mask"]))
        value = embeddings[0, :count]
        mx.eval(value)
        if not bool(mx.all(mx.isfinite(value)).item()):
            raise ValueError("Text encoder returned nonfinite conditioning")
        contexts.append(value)
        del embeddings, value
    del encoder
    gc.collect(); mx.clear_cache()
    observe("release-text", 2, 2)

    backbone = model.load("diffusion", WanModel(config), loading("diffusion"))
    positive = backbone.embed_text([contexts[0]])
    negative = backbone.embed_text([contexts[1]])
    mx.eval(positive, negative)
    del contexts
    shape = (16, (request["frameCount"] - 1) // 4 + 1, request["height"] // 8, request["width"] // 8)
    grid = (shape[1], shape[2] // 2, shape[3] // 2)
    seq_len = math.prod(grid)
    if max(grid) > 1024:
        raise ValueError("Requested latent axis exceeds this model's positional table")
    rope = backbone.prepare_rope([grid])
    sample = mx.random.normal(shape, dtype=mx.float32, key=mx.random.key(request["seed"]))
    mx.eval(sample)
    scheduler = FlowUniPCScheduler(solver_order=2)
    scheduler.set_timesteps(request["steps"], shift=request["shift"])
    for index, timestep in enumerate(scheduler.timesteps):
        observe("denoise", index, request["steps"])
        positive_flow = backbone([sample], mx.array([timestep.item()]), positive, seq_len, rope_cos_sin=rope)[0]
        mx.eval(positive_flow)
        check_cancel()
        negative_flow = backbone([sample], mx.array([timestep.item()]), negative, seq_len, rope_cos_sin=rope)[0]
        mx.eval(negative_flow)
        flow = negative_flow + request["guidanceScale"] * (positive_flow - negative_flow)
        sample = scheduler.step(flow, timestep, sample)
        mx.eval(sample)
        if not bool(mx.all(mx.isfinite(sample)).item()):
            raise ValueError("Denoising produced nonfinite latent")
        del positive_flow, negative_flow, flow
    del backbone, positive, negative, rope, scheduler, timestep
    gc.collect(); mx.clear_cache()
    observe("release-diffusion", request["steps"], request["steps"])

    vae = model.load("vae", WanVAE(), loading("vae"))
    iterator = vae.decode_chunks(sample[None])
    count = 0
    hasher = hashlib.sha256()
    raw_path = output / "frames.rgb"
    try:
        with raw_path.open("xb") as target:
            for chunk in iterator:
                observe("decode", count, request["frameCount"])
                validate_chunk_shape(chunk.shape, request, count)
                mx.eval(chunk)
                if not bool(mx.all(mx.isfinite(chunk)).item()):
                    raise ValueError("Decoder produced nonfinite frames")
                # Per-frame conversion, explicit [-1,1] -> RGB8 nearest rounding.
                for frame in range(chunk.shape[2]):
                    rgb = mx.clip(mx.round((chunk[0, :, frame].transpose(1, 2, 0) + 1) * 127.5), 0, 255).astype(mx.uint8)
                    data = np.asarray(rgb).tobytes(order="C")
                    if len(data) != request["width"] * request["height"] * 3:
                        raise ValueError("Decoded frame dimensions differ from request")
                    target.write(data); hasher.update(data); count += 1
                    del rgb, data
                del chunk
                gc.collect(); mx.clear_cache()
            target.flush(); os.fsync(target.fileno())
    finally:
        iterator.close()
    del iterator, vae, sample
    gc.collect(); mx.clear_cache()
    observe("released", count, request["frameCount"])
    if count != request["frameCount"]:
        raise ValueError("Decoded frame count differs; no cropping or padding is allowed")
    if identity(request_path) != request_identity or digest(request_path) != request_digest:
        raise ValueError("Submitted request changed during execution")
    if identity(model.manifest_path) != model.manifest_identity or digest(model.manifest_path) != model.manifest_digest:
        raise ValueError("Model preparation manifest changed during execution")
    result = {"schema": SCHEMA, "type": "result", "runID": request["runID"],
              "request": request, "requestSHA256": request_digest,
              "modelManifestSHA256": model.manifest_digest,
              "precision": model.manifest["precision"],
              "conditions": [{"tokenCount": c, "effectiveText": text} for _, c, text in conditions],
              "frames": {"file": "frames.rgb", "width": request["width"], "height": request["height"],
                         "frameCount": count, "fpsNumerator": request["fpsNumerator"],
                         "fpsDenominator": request["fpsDenominator"], "layout": "RGB8-top-down",
                         "colorInterpretation": "full-range Rec.709 display RGB", "sha256": hasher.hexdigest(),
                         "byteCount": raw_path.stat().st_size},
              "stages": stages, "seconds": time.monotonic() - started}
    exclusive_json(output / "result.json", result)
    print(json.dumps(result, ensure_ascii=False, allow_nan=False), flush=True)
    return result


def validate_chunk_shape(shape, request, delivered):
    if (len(shape) != 5 or shape[0] != 1 or shape[1] != 3 or shape[2] <= 0
            or shape[3] != request["height"] or shape[4] != request["width"]
            or delivered + shape[2] > request["frameCount"]):
        raise ValueError("Decoded chunk dimensions/count differ from the immutable request")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("request", "model", "tokenizer", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    def cancel(signum, frame):
        global _cancelled
        _cancelled = True
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", TOKENIZERS_PARALLELISM="false")
    try:
        run(args.request, args.model, args.tokenizer, args.output)
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        # Process termination and stderr are authoritative on errors; no result event
        # is fabricated. Partial private files survive for the host to diagnose.
        print("Video execution failed: " + str(error), file=sys.stderr, flush=True)
        return 130 if isinstance(error, InterruptedError) else 1


if __name__ == "__main__":
    raise SystemExit(main())
