"""Strict, offline loading of the pinned Wan tensor preparation.

The manifest is data, never an import/configuration program. Only the implemented
1.3B checkpoint is accepted. Conversion and runtime loading remain separate.
"""
from __future__ import annotations

import json
import hashlib
import os
import re
from pathlib import Path

from d_video_prepare import REVISION, checked_local, digest, identity


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field: " + key)
        result[key] = value
    return result


def read_snapshot(path: Path, maximum: int = 2 * 1024 * 1024):
    before = identity(checked_local(path))
    if before[2] > maximum:
        raise ValueError("JSON exceeds the declared read budget")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        s = os.fstat(source.fileno())
        if (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns) != before:
            raise ValueError("JSON changed before opening")
        data = source.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("JSON exceeds the declared read budget")
    value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object,
                       parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Nonfinite JSON")))
    if identity(path) != before:
        raise ValueError("JSON changed while reading")
    return value, hashlib.sha256(data).hexdigest(), before


def read_json(path: Path, maximum: int = 2 * 1024 * 1024):
    return read_snapshot(path, maximum)[0]


class PreparedModel:
    def __init__(self, root: Path):
        self.root = checked_local(root)
        self.manifest_path = self.root / "D-VIDEO-PREPARED.json"
        self.manifest, self.manifest_digest, self.manifest_identity = read_snapshot(self.manifest_path)
        m = self.manifest
        if (type(m.get("schemaVersion")) is not int or m["schemaVersion"] != 1
                or m.get("complete") is not True or m.get("revision") != REVISION
                or m.get("repository") != "Wan-AI/Wan2.1-T2V-1.3B"
                or m.get("preparation") != "original-names-tensor-shards-v1"):
            raise ValueError("Unsupported or incomplete prepared model")
        if m.get("precision") != {"text": "BF16", "diffusion": "BF16 with original FP32 time/head/modulation/norm tensors", "vae": "F32"}:
            raise ValueError("Prepared precision description differs from the actual profile")
        tensors = m.get("tensors")
        if not isinstance(tensors, list) or len(tensors) != 1261:
            raise ValueError("Prepared checkpoint must describe exactly 1261 original tensors")
        self.rows = {r: [] for r in ("text", "diffusion", "vae")}
        names, paths = set(), set()
        for row in tensors:
            if not isinstance(row, dict) or row.get("role") not in self.rows:
                raise ValueError("Invalid tensor role")
            role, name, path = row["role"], row.get("name"), row.get("path")
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.]+", name):
                raise ValueError("Invalid tensor name")
            if not isinstance(path, str) or not re.fullmatch(role + r"/[0-9]{4}\.safetensors", path):
                raise ValueError("Invalid tensor resource path")
            if (role, name) in names or path in paths:
                raise ValueError("Duplicate tensor name or resource")
            names.add((role, name)); paths.add(path)
            shape = row.get("shape")
            if (not isinstance(shape, list) or not shape or len(shape) > 5
                    or any(type(v) is not int or v <= 0 for v in shape)
                    or type(row.get("size")) is not int or row["size"] <= 0
                    or not isinstance(row.get("sha256"), str)
                    or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"])):
                raise ValueError("Invalid tensor dimensions, size or digest")
            expected_dtype = "F32" if role == "vae" or (role == "diffusion" and (
                name.startswith(("time_embedding.", "time_projection.", "head."))
                or name.endswith(".modulation")
                or any(part.startswith("norm") for part in name.split(".")))) else "BF16"
            if row.get("dtype") != expected_dtype:
                raise ValueError("Prepared precision differs from the approved mixed precision")
            self.rows[role].append(row)
        if {role: len(rows) for role, rows in self.rows.items()} != {"text": 242, "diffusion": 825, "vae": 194}:
            raise ValueError("Checkpoint component counts differ")

    def load(self, role: str, module, checkpoint=None):
        import mlx.core as mx
        from mlx.utils import tree_flatten

        generated = {"freqs"} if role == "diffusion" else ({"mean", "std", "inv_std"} if role == "vae" else set())
        expected = dict(tree_flatten(module.parameters()))
        learned = set(expected) - generated
        rows = self.rows[role]
        mapped = {}
        for row in rows:
            name = row["name"]
            if role == "vae" and (name.startswith("encoder.") or name.startswith("conv1.")):
                continue  # Explicitly excluded encoder, unsupported by the T2V decoder.
            target = mapped_name(role, name)
            if target not in learned or target in mapped:
                raise ValueError("Unexpected or duplicate learned parameter: " + target)
            mapped[target] = row
        if set(mapped) != learned:
            raise ValueError("Missing learned parameters: " + str(sorted(learned - set(mapped))))
        for index, (target, row) in enumerate(mapped.items()):
            if checkpoint:
                checkpoint(index, len(mapped))
            path = checked_local(self.root / row["path"])
            before = identity(path)
            if before[2] != row["size"] or digest(path) != row["sha256"] or identity(path) != before:
                raise ValueError("Prepared tensor failed integrity verification: " + row["name"])
            data = mx.load(str(path))
            if set(data) != {row["name"]}:
                raise ValueError("Tensor file keys differ from manifest")
            value = data[row["name"]]
            dtype = mx.float32 if row["dtype"] == "F32" else mx.bfloat16
            if list(value.shape) != row["shape"] or value.dtype != dtype:
                raise ValueError("Tensor shape or precision differs from manifest")
            if role == "diffusion" and row["name"] == "patch_embedding.weight":
                value = value.reshape(value.shape[0], -1)
            elif role == "vae" and value.ndim == 5 and row["name"].endswith(".weight"):
                value = value.transpose(0, 2, 3, 4, 1)
            elif role == "vae" and value.ndim == 4 and row["name"].endswith(".weight"):
                value = value.transpose(0, 2, 3, 1)
            if value.shape != expected[target].shape:
                raise ValueError("Mapped parameter shape differs: " + target)
            # All keys/shapes were checked above; replace one tensor at a time,
            # never evaluate the model's unfilled random initialization.
            module.load_weights([(target, value)], strict=False)
            mx.eval(value)
            if identity(path) != before:
                raise ValueError("Tensor changed during load")
            del data, value
        if identity(self.manifest_path) != self.manifest_identity:
            raise ValueError("Prepared manifest changed while loading")
        return module


def mapped_name(role: str, name: str) -> str:
    if role == "text":
        return name.replace(".ffn.gate.0.", ".ffn.gate_proj.")
    if role == "diffusion":
        name = name.replace("patch_embedding.", "patch_embedding_proj.")
        for kind in ("text", "time"):
            for old, new in (("0", "0"), ("2", "1")):
                name = name.replace(kind + "_embedding." + old + ".", kind + "_embedding_" + new + ".")
        name = name.replace("time_projection.1.", "time_projection.")
        name = name.replace(".ffn.0.", ".ffn.fc1.").replace(".ffn.2.", ".ffn.fc2.")
    return name
