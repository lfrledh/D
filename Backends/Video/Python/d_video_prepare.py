"""Offline preparation of the approved Wan 2.1 originals, without model execution.

One tensor per safetensors file bounds conversion temporaries. Original tensor names
are retained; backend-specific layout conversion is a separate, validated operation.
PyTorch is preparation-only, and restricted weights_only loading is mandatory.
"""
from __future__ import annotations

import argparse
import gc
import hashlib
import json
import os
from pathlib import Path
import resource
import stat
import time
import uuid
import pickle

REVISION = "37ec512624d61f7aa208f7ea8140a131f93afc9a"
FILES = {
    "text": ("models_t5_umt5-xxl-enc-bf16.pth", "7cace0da2b446bbbbc57d031ab6cf163a3d59b366da94e5afe36745b746fd81d", 11361920418, "BF16"),
    "diffusion": ("diffusion_pytorch_model.safetensors", "96b6b242ca1c2f24e9d02cd6596066fab6d310e2d7538f33ae267cb18d957e8f", 5676070424, "BF16"),
    "vae": ("Wan2.1_VAE.pth", "38071ab59bd94681c686fa51d75a1968f64e470262043be31f7a094e442fd981", 507609880, "F32"),
}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(4 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def checked_local(path: Path) -> Path:
    if not path.is_absolute() or ".." in path.parts or "\0" in str(path):
        raise ValueError("An unambiguous absolute local path is required")
    for parent in reversed((path, *path.parents)):
        if parent.exists() and parent.is_symlink():
            raise ValueError("Symbolic-link paths are not supported for preparation")
    return path


def identity(path: Path) -> tuple[int, ...]:
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode):
        raise ValueError("Expected an ordinary model resource: " + str(path))
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns


def exclusive_json(path: Path, value: dict) -> None:
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex + ".partial")
    published = False
    try:
        with temporary.open("x", encoding="utf-8") as target:
            json.dump(value, target, ensure_ascii=False, indent=2, allow_nan=False)
            target.flush()
            os.fsync(target.fileno())
        if json.loads(temporary.read_text(encoding="utf-8")) != value:
            raise ValueError("Prepared manifest failed readback")
        os.link(temporary, path)  # Atomic, exclusive publication in this private directory.
        published = True
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except OSError as error:
        if published:
            raise OSError(f"Verified manifest published at {path}, but final directory synchronization failed; published file preserved: {error}") from error
        raise
    finally:
        if temporary.exists():
            temporary.unlink()  # Only this invocation's private random temporary file.


def prepare(source: Path, destination: Path) -> dict:
    source, destination = checked_local(source), checked_local(destination)
    if not source.is_dir() or not destination.parent.is_dir():
        raise ValueError("Source and destination parent directories must already exist")
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("Prepared output must be separate from originals")
    if destination.exists() or destination.is_symlink():
        raise FileExistsError("Preparation never overwrites an existing destination")
    identities = {}
    for role, (name, expected, size, dtype) in FILES.items():
        path = checked_local(source / name)
        before = identity(path)
        if before[2] != size or digest(path) != expected or identity(path) != before:
            raise ValueError("Original model size, SHA-256 or identity mismatch: " + name)
        identities[role] = before

    # An incomplete directory is retained as evidence on failure. Only the final
    # manifest marks a completed preparation, never directory presence alone.
    destination.mkdir(mode=0o700)
    import torch
    from safetensors import safe_open
    from safetensors.torch import save_file

    torch.set_num_threads(2)
    manifest = {"schemaVersion": 1, "repository": "Wan-AI/Wan2.1-T2V-1.3B",
                "revision": REVISION, "preparation": "original-names-tensor-shards-v1",
                "precision": {"text": "BF16", "diffusion": "BF16 with original FP32 time/head/modulation/norm tensors", "vae": "F32"},
                "tensors": [], "originals": [], "complete": False}
    started = time.monotonic()
    for role, (name, expected, size, dtype) in FILES.items():
        path = source / name
        if identity(path) != identities[role]:
            raise ValueError("Original changed during preparation: " + name)
        out_dir = destination / role
        out_dir.mkdir(mode=0o700)
        state = None
        handle = None
        if path.suffix == ".pth":
            # Do not fall back to a full T5 copy or unrestricted unpickling.
            state = torch.load(path, map_location="cpu", weights_only=True, mmap=True)
            if not isinstance(state, dict):
                raise ValueError("Checkpoint must contain a plain tensor state mapping")
            keys = sorted(state)
            get = state.__getitem__
        else:
            handle = safe_open(path, framework="pt", device="cpu")
            keys = sorted(handle.keys())
            get = handle.get_tensor
        for index, key in enumerate(keys):
            value = get(key)
            if not isinstance(key, str) or not key or not isinstance(value, torch.Tensor) or not value.is_floating_point():
                raise ValueError("Unexpected non-floating checkpoint tensor")
            if not bool(torch.isfinite(value).all()):
                raise ValueError("Nonfinite original tensor: " + key)
            # Match the reference's full-precision time/head/modulation and
            # normalization paths without first rounding their original weights.
            preserve_fp32 = role == "diffusion" and (
                key.startswith(("time_embedding.", "time_projection.", "head."))
                or key.endswith(".modulation")
                or any(part.startswith("norm") for part in key.split(".")))
            tensor_dtype = "F32" if preserve_fp32 or role == "vae" else "BF16"
            target_dtype = torch.float32 if tensor_dtype == "F32" else torch.bfloat16
            converted = value.detach().to(dtype=target_dtype, device="cpu").contiguous()
            if not bool(torch.isfinite(converted).all()):
                raise ValueError("Nonfinite prepared tensor after precision conversion: " + key)
            relative = f"{role}/{index:04d}.safetensors"
            output = destination / relative
            # Exclusive private destination and generated filenames; no caller path
            # or original model tensor name is used as a filesystem component.
            if output.exists():
                raise FileExistsError(str(output))
            save_file({key: converted}, output)
            with output.open("rb") as saved:
                os.fsync(saved.fileno())
            with safe_open(output, framework="pt", device="cpu") as saved:
                restored = saved.get_tensor(key)
                if restored.dtype != target_dtype or not torch.equal(restored, converted):
                    raise ValueError("Prepared tensor did not round-trip exactly: " + key)
            manifest["tensors"].append({"role": role, "name": key, "path": relative,
                                         "shape": list(converted.shape), "dtype": tensor_dtype,
                                         "size": output.stat().st_size, "sha256": digest(output)})
            del restored, converted, value
            gc.collect()
        del get, state, handle
        gc.collect()
        if identity(path) != identities[role]:
            raise ValueError("Original changed while converting: " + name)
        manifest["originals"].append({"path": name, "size": size, "sha256": expected})
        print(json.dumps({"stage": "prepared", "component": role, "tensorCount": len(keys),
                          "peakRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}), flush=True)

    manifest["complete"] = True
    manifest["seconds"] = time.monotonic() - started
    manifest["peakRSSBytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    exclusive_json(destination / "D-VIDEO-PREPARED.json", manifest)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.source, args.destination)
        print(json.dumps({"complete": True, "tensorCount": len(result["tensors"]),
                          "peakRSSBytes": result["peakRSSBytes"]}), flush=True)
        return 0
    except (OSError, ValueError, RuntimeError, pickle.UnpicklingError) as error:
        print("Video model preparation failed: " + str(error), file=__import__("sys").stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
